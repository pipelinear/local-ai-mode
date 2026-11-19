import AppKit
import Combine

struct RunningAppInfo: Identifiable, Hashable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var icon: NSImage?
    var policy: AppDescriptor.Policy
    var isHidden: Bool
    var isActive: Bool
    var launchDate: Date?
    var decision: CloseDecision
    /// Physical footprint including helper processes, when measurable.
    var memoryBytes: UInt64?

    var descriptor: AppDescriptor {
        AppDescriptor(name: name, bundleIdentifier: bundleIdentifier, bundlePath: bundlePath, pid: pid, activationPolicy: policy)
    }

    static func == (lhs: RunningAppInfo, rhs: RunningAppInfo) -> Bool {
        lhs.pid == rhs.pid && lhs.decision == rhs.decision && lhs.memoryBytes == rhs.memoryBytes
            && lhs.isHidden == rhs.isHidden && lhs.isActive == rhs.isActive
    }
    func hash(into hasher: inout Hasher) { hasher.combine(pid) }
}

/// Lists running applications and quits/relaunches them through NSWorkspace / NSRunningApplication.
@MainActor
final class ApplicationManager: ObservableObject {
    @Published private(set) var apps: [RunningAppInfo] = []
    /// Apps launched by the user while AI Mode is on.
    @Published private(set) var launchedDuringAIMode: [RunningAppInfo] = []

    var policyProvider: () -> ExclusionPolicy = {
        ExclusionPolicy(ownBundleIdentifier: Bundle.main.bundleIdentifier,
                        ownPID: ProcessInfo.processInfo.processIdentifier,
                        userExcludedBundleIDs: [], includeMenuBarApps: false)
    }
    var isTrackingLaunches = false

    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private var memoryTask: Task<Void, Never>?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in names {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didLaunchApplicationNotification, let app { self.noteLaunch(app) }
                    if name == NSWorkspace.didTerminateApplicationNotification, let app {
                        self.launchedDuringAIMode.removeAll { $0.pid == app.processIdentifier }
                    }
                    self.scheduleRefresh()
                }
            })
        }
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
    }

    // MARK: Listing

    static func descriptor(for app: NSRunningApplication) -> AppDescriptor {
        let policy: AppDescriptor.Policy
        switch app.activationPolicy {
        case .regular: policy = .regular
        case .accessory: policy = .accessory
        default: policy = .prohibited
        }
        return AppDescriptor(name: app.localizedName ?? app.bundleIdentifier ?? "PID \(app.processIdentifier)",
                             bundleIdentifier: app.bundleIdentifier,
                             bundlePath: app.bundleURL?.path,
                             pid: app.processIdentifier,
                             activationPolicy: policy)
    }

    /// Ollama's server may be hosted by a GUI app (e.g. Terminal running `ollama serve`); protect those.
    static func ollamaHostPIDs() -> Set<Int32> {
        let table = ProcessInspector.parentTable()
        var result = Set<Int32>()
        for proc in ProcessInspector.ollamaProcesses() {
            result.formUnion(ProcessInspector.ancestors(of: proc.pid, table: table))
        }
        return result
    }

    func refresh() {
        let policy = policyProvider()
        let previousMemory = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0.memoryBytes) })
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && !$0.isTerminated }
            .map { app in
                let d = Self.descriptor(for: app)
                return RunningAppInfo(pid: d.pid, name: d.name, bundleIdentifier: d.bundleIdentifier,
                                      bundlePath: d.bundlePath, icon: app.icon, policy: d.activationPolicy,
                                      isHidden: app.isHidden, isActive: app.isActive, launchDate: app.launchDate,
                                      decision: policy.decision(for: d), memoryBytes: previousMemory[d.pid] ?? nil)
            }
            .sorted { lhs, rhs in
                if lhs.policy != rhs.policy { return lhs.policy == .regular }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    /// Measures per-app memory off the main thread. Only called while the dashboard is visible.
    func refreshMemory() {
        memoryTask?.cancel()
        let pids = apps.map(\.pid)
        memoryTask = Task { [weak self] in
            let footprints = await Task.detached(priority: .utility) {
                ProcessInspector.footprintsIncludingDescendants(of: pids)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apps = self.apps.map { var a = $0; a.memoryBytes = footprints[a.pid]; return a }
        }
    }

    var appsToClose: [RunningAppInfo] { apps.filter { $0.decision.willClose } }

    var estimatedReclaimableBytes: UInt64 {
        appsToClose.reduce(0) { $0 &+ ($1.memoryBytes ?? 0) }
    }

    // MARK: Launch tracking while AI Mode is on

    private func noteLaunch(_ app: NSRunningApplication) {
        guard isTrackingLaunches, app.activationPolicy == .regular else { return }
        let d = Self.descriptor(for: app)
        let decision = policyProvider().decision(for: d)
        guard decision.willClose else { return }
        let info = RunningAppInfo(pid: d.pid, name: d.name, bundleIdentifier: d.bundleIdentifier, bundlePath: d.bundlePath,
                                  icon: app.icon, policy: d.activationPolicy, isHidden: false, isActive: false,
                                  launchDate: app.launchDate, decision: decision, memoryBytes: nil)
        if !launchedDuringAIMode.contains(where: { $0.pid == info.pid }) {
            launchedDuringAIMode.append(info)
        }
    }

    func clearLaunchedDuringAIMode() { launchedDuringAIMode.removeAll() }

    // MARK: Quitting

    /// Asks each app to quit (the same as choosing Quit from its menu). Apps may show save dialogs; we wait up to
    /// `timeout` seconds and then report those still running instead of blocking forever. Never force-quits.
    func terminateGracefully(_ entries: [AppSnapshotEntry], timeout: TimeInterval,
                             progress: @escaping (String) -> Void) async -> TerminationOutcome {
        var outcome = TerminationOutcome()
        var pending: [(AppSnapshotEntry, NSRunningApplication)] = []
        for entry in entries {
            guard let app = NSRunningApplication(processIdentifier: entry.processIdentifier), !app.isTerminated else {
                outcome.closed.append(entry) // already gone
                continue
            }
            progress("Asking \(entry.name) to quit")
            if !app.terminate() {
                // terminate() returns false if the request could not be delivered; keep tracking it anyway.
                progress("\(entry.name) did not accept the quit request yet")
            }
            pending.append((entry, app))
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !pending.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            pending.removeAll { entry, app in
                if app.isTerminated {
                    outcome.closed.append(entry)
                    progress("\(entry.name) quit")
                    return true
                }
                return false
            }
            if Task.isCancelled { break }
        }
        outcome.stillRunning = pending.map(\.0)
        return outcome
    }

    /// Waits a further period for specific apps (e.g. while the user answers save dialogs).
    func waitForTermination(pids: [pid_t], timeout: TimeInterval) async -> Set<pid_t> {
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = Set(pids)
        while !remaining.isEmpty && Date() < deadline {
            remaining = remaining.filter { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                return !app.isTerminated
            }
            if remaining.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return remaining
    }

    /// Advanced, explicitly confirmed action. Unsaved work in the app is lost.
    func forceQuit(pid: pid_t) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return true }
        let policy = policyProvider()
        guard policy.decision(for: Self.descriptor(for: app)).willClose else { return false }
        _ = app.forceTerminate()
        let remaining = await waitForTermination(pids: [pid], timeout: 5)
        return remaining.isEmpty
    }

    func requestQuit(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    func isRunning(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }
}
