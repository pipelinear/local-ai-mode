import Foundation
import ServiceManagement
import Combine

enum OllamaLaunchMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Open Ollama.app (the menu-bar app). Server environment cannot be customised.
    case app
    /// Run `ollama serve` as a child process, which lets Local AI Mode pass documented OLLAMA_* settings.
    case serve

    var id: String { rawValue }
    var label: String {
        switch self {
        case .app: return "Ollama.app"
        case .serve: return "ollama serve (applies server settings)"
        }
    }
}

enum KVCacheType: String, Codable, CaseIterable, Identifiable, Sendable {
    case f16, q8_0, q4_0
    var id: String { rawValue }
}

/// All persisted preferences. Stored as one JSON blob in UserDefaults.
struct AppSettings: Codable, Equatable, Sendable {
    // General
    var showInMenuBar = true
    var startMinimized = false
    var restoreAppsAutomatically = true
    var confirmBeforeClosing = true

    // Applications
    var userExcludedBundleIDs: [String] = []
    /// Version of `AppSettings.defaultExclusions` already merged in, so removed defaults never come back.
    var seededDefaultExclusionsVersion = 0
    var includeMenuBarApps = false
    var gracefulQuitTimeout: Double = 20
    var captureBrowserTabs = false
    var captureDocumentsWithAccessibility = true

    // Ollama
    var ollamaBaseURL = "http://localhost:11434"
    var selectedModel: String?
    /// Ollama keep_alive in minutes. -1 = keep loaded indefinitely.
    var keepAliveMinutes: Int = -1
    /// 0 = use the model's default.
    var contextLength: Int = 0
    var launchMethod: OllamaLaunchMethod = .app
    var keepOllamaRunningAfterExit = true
    var unloadTimeout: Double = 60
    var modelLoadTimeout: Double = 600
    // Server settings (only applied when Local AI Mode starts `ollama serve`)
    var numParallel: Int = 1
    var maxLoadedModels: Int = 1
    var flashAttention = true
    var kvCacheType: KVCacheType = .f16

    // Power
    var disableLowPowerMode = true
    var preventIdleSleep = true

    var keepAliveAPIValue: OllamaKeepAlive {
        keepAliveMinutes < 0 ? .forever : .duration(seconds: keepAliveMinutes * 60)
    }

    /// Apps kept open by default (editable in Settings › Applications). Closing them would interrupt an
    /// assistant session or a terminal that may be driving Ollama.
    static let defaultExclusions = ["com.anthropic.claudefordesktop", "com.apple.Terminal"]
    static let defaultExclusionsVersion = 1

    init() {}

    /// Merges default exclusions once per defaults version. Returns true if anything changed.
    @discardableResult
    mutating func seedDefaultExclusions() -> Bool {
        guard seededDefaultExclusionsVersion < Self.defaultExclusionsVersion else { return false }
        userExcludedBundleIDs = Array(Set(userExcludedBundleIDs).union(Self.defaultExclusions)).sorted()
        seededDefaultExclusionsVersion = Self.defaultExclusionsVersion
        return true
    }

    // Decode tolerantly so new fields never wipe old preferences.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        showInMenuBar = v(.showInMenuBar, d.showInMenuBar)
        startMinimized = v(.startMinimized, d.startMinimized)
        restoreAppsAutomatically = v(.restoreAppsAutomatically, d.restoreAppsAutomatically)
        confirmBeforeClosing = v(.confirmBeforeClosing, d.confirmBeforeClosing)
        userExcludedBundleIDs = v(.userExcludedBundleIDs, d.userExcludedBundleIDs)
        seededDefaultExclusionsVersion = v(.seededDefaultExclusionsVersion, d.seededDefaultExclusionsVersion)
        includeMenuBarApps = v(.includeMenuBarApps, d.includeMenuBarApps)
        gracefulQuitTimeout = v(.gracefulQuitTimeout, d.gracefulQuitTimeout)
        captureBrowserTabs = v(.captureBrowserTabs, d.captureBrowserTabs)
        captureDocumentsWithAccessibility = v(.captureDocumentsWithAccessibility, d.captureDocumentsWithAccessibility)
        ollamaBaseURL = v(.ollamaBaseURL, d.ollamaBaseURL)
        selectedModel = v(.selectedModel, d.selectedModel)
        keepAliveMinutes = v(.keepAliveMinutes, d.keepAliveMinutes)
        contextLength = v(.contextLength, d.contextLength)
        launchMethod = v(.launchMethod, d.launchMethod)
        keepOllamaRunningAfterExit = v(.keepOllamaRunningAfterExit, d.keepOllamaRunningAfterExit)
        unloadTimeout = v(.unloadTimeout, d.unloadTimeout)
        modelLoadTimeout = v(.modelLoadTimeout, d.modelLoadTimeout)
        numParallel = v(.numParallel, d.numParallel)
        maxLoadedModels = v(.maxLoadedModels, d.maxLoadedModels)
        flashAttention = v(.flashAttention, d.flashAttention)
        kvCacheType = v(.kvCacheType, d.kvCacheType)
        disableLowPowerMode = v(.disableLowPowerMode, d.disableLowPowerMode)
        preventIdleSleep = v(.preventIdleSleep, d.preventIdleSleep)
    }
}

@MainActor
final class SettingsManager: ObservableObject {
    static let defaultsKey = "LocalAIMode.settings.v1"

    @Published var settings: AppSettings {
        didSet { if settings != oldValue { save() } }
    }
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @Published var launchAtLoginError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        var seeded = settings
        if seeded.seedDefaultExclusions() {
            settings = seeded
            save() // didSet does not run during init
        }
        refreshLaunchAtLogin()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Launch at login (SMAppService — no helper, no privileges)

    var launchAtLogin: Bool { launchAtLoginStatus == .enabled }

    func refreshLaunchAtLogin() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
        if launchAtLoginStatus == .requiresApproval {
            launchAtLoginError = "Approve Local AI Mode in System Settings › General › Login Items."
        }
    }

    // MARK: Exclusions

    func setExcluded(_ bundleID: String, excluded: Bool) {
        var set = settings.userExcludedBundleIDs
        if excluded {
            if !set.contains(bundleID) { set.append(bundleID) }
        } else {
            set.removeAll { $0 == bundleID }
        }
        settings.userExcludedBundleIDs = set.sorted()
    }
}
