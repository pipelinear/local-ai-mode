import Foundation

// MARK: - Workspace snapshot

/// A browser tab captured (optionally) through Apple Events so it can be reopened later.
struct BrowserTab: Codable, Hashable, Sendable {
    var url: String
    var title: String?
}

/// One running application recorded when AI Mode was enabled.
struct AppSnapshotEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String { bundleIdentifier ?? bundlePath }
    var name: String
    var bundleIdentifier: String?
    var bundlePath: String
    var processIdentifier: Int32
    var wasHidden: Bool
    var wasActive: Bool
    var launchOrder: Int
    /// Document file URLs reported by the Accessibility API (`AXDocument`), when permitted.
    var documentURLs: [String]
    /// Number of on-screen windows reported by the Accessibility API, when permitted.
    var windowCount: Int?
    /// Browser tabs captured via Apple Events, when the feature is enabled and permitted.
    var browserTabs: [BrowserTab]
    /// Set once Local AI Mode confirmed the app actually terminated.
    var wasClosedByAIMode: Bool

    init(name: String,
         bundleIdentifier: String?,
         bundlePath: String,
         processIdentifier: Int32,
         wasHidden: Bool = false,
         wasActive: Bool = false,
         launchOrder: Int = 0,
         documentURLs: [String] = [],
         windowCount: Int? = nil,
         browserTabs: [BrowserTab] = [],
         wasClosedByAIMode: Bool = false) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.processIdentifier = processIdentifier
        self.wasHidden = wasHidden
        self.wasActive = wasActive
        self.launchOrder = launchOrder
        self.documentURLs = documentURLs
        self.windowCount = windowCount
        self.browserTabs = browserTabs
        self.wasClosedByAIMode = wasClosedByAIMode
    }
}

struct WorkspaceSnapshot: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = WorkspaceSnapshot.currentSchemaVersion
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var hostName: String = ProcessInfo.processInfo.hostName
    var applications: [AppSnapshotEntry]
    var accessibilityWasAvailable: Bool
    var browserCaptureWasEnabled: Bool

    var closedApplications: [AppSnapshotEntry] {
        applications.filter(\.wasClosedByAIMode)
    }
}

// MARK: - Power settings

enum PowerSource: String, Codable, Sendable, CaseIterable {
    case battery = "b"
    case ac = "c"
}

/// The pmset key used on this macOS version (`powermode` on newer releases, `lowpowermode` on older ones).
struct PowerModeSetting: Codable, Hashable, Sendable {
    var key: String
    var source: PowerSource
    var value: Int
}

/// Settings Local AI Mode changed, recorded *before* changing them so they can be restored.
struct ChangedSettingsRecord: Codable, Hashable, Sendable {
    var originalPowerModes: [PowerModeSetting] = []
    var powerModesChanged: Bool = false
}

// MARK: - Session journal

enum SessionPhase: String, Codable, Sendable {
    case activating
    case active
    case deactivating
    /// AI Mode ended but the user chose not to restore apps automatically.
    case restorePending
}

/// Persistent record of an AI Mode session. Written atomically at each step so a crash can be recovered.
struct SessionJournal: Codable, Hashable, Sendable {
    var sessionID: UUID = UUID()
    var phase: SessionPhase
    var startedAt: Date = Date()
    var updatedAt: Date = Date()
    var snapshot: WorkspaceSnapshot
    var changedSettings: ChangedSettingsRecord = ChangedSettingsRecord()
    var ollamaStartedByAIMode: Bool = false
    var requestedModel: String?
    var appLaunchPID: Int32 = ProcessInfo.processInfo.processIdentifier
    var memoryBefore: MemorySample?
}

// MARK: - Memory

enum MemoryPressureLevel: Int, Codable, Sendable, Comparable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

/// One measurement of system memory taken from `host_statistics64` and `sysctl`.
struct MemorySample: Codable, Hashable, Sendable, Identifiable {
    var id: Date { timestamp }
    var timestamp: Date
    var totalBytes: UInt64
    /// Anonymous memory owned by processes (internal pages minus purgeable) — Activity Monitor's "App Memory".
    var appBytes: UInt64
    var wiredBytes: UInt64
    /// Physical memory occupied by the compressor.
    var compressedBytes: UInt64
    /// File-backed and purgeable pages that macOS can drop instantly — "Cached Files".
    var cachedBytes: UInt64
    var freeBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    var pressure: MemoryPressureLevel

    /// Activity Monitor's "Memory Used".
    var usedBytes: UInt64 { appBytes &+ wiredBytes &+ compressedBytes }
    /// Memory obtainable without swapping: free plus reclaimable cache.
    var availableBytes: UInt64 { totalBytes > usedBytes ? totalBytes - usedBytes : 0 }
    var reclaimableBytes: UInt64 { cachedBytes &+ freeBytes }
}

struct CPUSample: Hashable, Sendable {
    var timestamp: Date
    /// 0...1 across all cores.
    var usage: Double
    var userFraction: Double
    var systemFraction: Double
}

enum ThermalLevel: String, Codable, Sendable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    var label: String { rawValue.capitalized }
}

// MARK: - Mode state

enum ActivationStep: String, Sendable, CaseIterable {
    case savingSnapshot = "Saving workspace snapshot"
    case closingApps = "Closing applications"
    case optimizingPerformance = "Applying performance settings"
    case startingOllama = "Starting Ollama"
    case loadingModel = "Loading model"
    case verifying = "Verifying"
}

enum DeactivationStep: String, Sendable, CaseIterable {
    case unloadingModels = "Unloading models"
    case stoppingOllama = "Stopping Ollama"
    case restoringSettings = "Restoring settings"
    case restoringApps = "Reopening applications"
}

enum ModeState: Equatable, Sendable {
    case normal
    case awaitingConfirmation
    case activating(ActivationStep)
    case active
    case deactivating(DeactivationStep)
    case recoveryNeeded

    var isTransitioning: Bool {
        switch self {
        case .activating, .deactivating: return true
        default: return false
        }
    }

    var isAIModeOn: Bool {
        switch self {
        case .active, .activating: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .normal: return "Normal Mode"
        case .awaitingConfirmation: return "Review Applications"
        case .activating(let step): return step.rawValue + "…"
        case .active: return "AI Performance Mode"
        case .deactivating(let step): return step.rawValue + "…"
        case .recoveryNeeded: return "Recovery Needed"
        }
    }
}

// MARK: - Model status

enum ModelLoadStatus: Equatable, Sendable {
    case idle
    case loading(model: String, since: Date)
    case loaded(model: String)
    case unloading(model: String)
    case failed(model: String, message: String)
    /// AI Mode is on but the model is no longer resident (evicted, or Ollama was quit).
    case lost(model: String, reason: String)

    var label: String {
        switch self {
        case .idle: return "Not loaded"
        case .loading(let m, _): return "Loading \(m)…"
        case .loaded(let m): return "Loaded: \(m)"
        case .unloading(let m): return "Unloading \(m)…"
        case .failed(_, let msg): return "Failed: \(msg)"
        case .lost(_, let reason): return reason
        }
    }
}

// MARK: - Reports

struct TerminationOutcome: Sendable, Hashable {
    var closed: [AppSnapshotEntry] = []
    /// Apps still running after the graceful timeout (often waiting on a save dialog).
    var stillRunning: [AppSnapshotEntry] = []
}

struct RestoreFailure: Hashable, Sendable, Identifiable {
    var id: String { appName + reason }
    var appName: String
    var reason: String
}

struct RestoreReport: Sendable, Hashable {
    var reopened: [String] = []
    var alreadyRunning: [String] = []
    var relocated: [String] = []
    var failures: [RestoreFailure] = []
    var date = Date()

    var summary: String {
        var parts = ["Reopened \(reopened.count) app\(reopened.count == 1 ? "" : "s")"]
        if !alreadyRunning.isEmpty { parts.append("\(alreadyRunning.count) already running") }
        if !failures.isEmpty { parts.append("\(failures.count) could not be restored") }
        return parts.joined(separator: " · ")
    }
}

/// A user-visible event shown in the activity log.
struct ActivityEvent: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case info, success, warning, error }
    var id = UUID()
    var date = Date()
    var kind: Kind
    var message: String
}

// MARK: - Byte formatting

enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    static func signed(_ delta: Int64) -> String {
        let sign = delta >= 0 ? "+" : "−"
        return sign + string(UInt64(abs(delta)))
    }
}
