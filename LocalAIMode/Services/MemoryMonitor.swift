import Foundation
import Darwin
import Combine

/// Reads real system measurements from Mach and sysctl. No allocation tricks, no cache purging.
enum SystemMetrics {
    private static let hostPort: mach_port_t = mach_host_self()

    static var pageSize: UInt64 {
        var size: vm_size_t = 0
        host_page_size(hostPort, &size)
        return UInt64(size)
    }

    static func memorySample() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = pageSize
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let swap = swapUsage()
        return MemorySample(
            timestamp: Date(),
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            appBytes: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            cachedBytes: (UInt64(stats.external_page_count) + purgeable) * page,
            freeBytes: UInt64(stats.free_count) * page,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            pressure: pressureLevel()
        )
    }

    static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// The kernel's own pressure assessment (what drives Activity Monitor's pressure graph colours).
    static func pressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        return MemoryPressureLevel(rawValue: Int(level)) ?? .unknown
    }

    /// Cumulative CPU ticks (user, system, idle, nice) across all cores.
    static func cpuTicks() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3))
    }
}

struct ChartMarker: Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var label: String
}

/// Samples memory/CPU/thermal state at an adaptive interval: frequent while the dashboard is visible,
/// infrequent otherwise. Memory-pressure changes are also delivered immediately by a dispatch source.
@MainActor
final class MemoryMonitor: ObservableObject {
    static let visibleInterval: TimeInterval = 2
    static let backgroundInterval: TimeInterval = 15
    static let historyLimit = 900 // 30 min at 2 s

    @Published private(set) var latest: MemorySample?
    @Published private(set) var history: [MemorySample] = []
    @Published private(set) var cpu: CPUSample?
    @Published private(set) var thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
    @Published private(set) var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var markers: [ChartMarker] = []
    @Published var beforeSample: MemorySample?
    @Published var afterSample: MemorySample?

    private var timer: Timer?
    private var interval: TimeInterval = MemoryMonitor.backgroundInterval
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private var visibleClients = 0
    /// Extra callback run on every tick (used to poll Ollama while AI Mode is on).
    var onTick: (() -> Void)?

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermal = ThermalLevel(ProcessInfo.processInfo.thermalState) }
        })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
        source.resume()
        pressureSource = source
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        pressureSource?.cancel()
    }

    func start() {
        sample()
        schedule()
    }

    /// Reference-counted: any visible view that needs live data calls this on appear/disappear.
    func setVisible(_ visible: Bool) {
        visibleClients = max(0, visibleClients + (visible ? 1 : -1))
        let newInterval = visibleClients > 0 ? Self.visibleInterval : Self.backgroundInterval
        if newInterval != interval {
            interval = newInterval
            schedule()
            if visible { sample() }
        }
    }

    var isDashboardVisible: Bool { visibleClients > 0 }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample()
                self?.onTick?()
            }
        }
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func sample() {
        if let s = SystemMetrics.memorySample() {
            latest = s
            history.append(s)
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }
        if let ticks = SystemMetrics.cpuTicks() {
            if let last = lastTicks {
                let user = Double(ticks.user &- last.user) + Double(ticks.nice &- last.nice)
                let system = Double(ticks.system &- last.system)
                let idle = Double(ticks.idle &- last.idle)
                let total = user + system + idle
                if total > 0 {
                    cpu = CPUSample(timestamp: Date(), usage: (user + system) / total,
                                    userFraction: user / total, systemFraction: system / total)
                }
            }
            lastTicks = ticks
        }
        thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func addMarker(_ label: String) {
        markers.append(ChartMarker(date: Date(), label: label))
        if let first = history.first?.timestamp { markers.removeAll { $0.date < first } }
    }

    /// Takes a fresh sample now and returns it (used for before/after comparison).
    func captureNow() -> MemorySample? {
        sample()
        return latest
    }
}
