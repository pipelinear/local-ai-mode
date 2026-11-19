import Foundation

/// Pure description of a running app — decoupled from NSRunningApplication so the policy is testable.
struct AppDescriptor: Hashable, Sendable {
    enum Policy: Sendable { case regular, accessory, prohibited }

    var name: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var pid: Int32
    var activationPolicy: Policy
}

enum CloseDecision: Hashable, Sendable {
    /// Required by macOS, Ollama or Local AI Mode itself. Never closed.
    case protected(reason: String)
    /// Excluded by the user.
    case userExcluded
    /// Not part of AI Mode's scope (e.g. menu-bar utilities when that option is off).
    case notIncluded(reason: String)
    case willClose

    var willClose: Bool { self == .willClose }
    var isProtected: Bool { if case .protected = self { return true } else { return false } }

    var label: String {
        switch self {
        case .protected(let reason): return reason
        case .userExcluded: return "Excluded by you"
        case .notIncluded(let reason): return reason
        case .willClose: return "Will close"
        }
    }
}

struct ExclusionPolicy: Sendable {
    /// Bundle IDs that must never be closed, regardless of user settings.
    static let systemBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.WindowManager",
        "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent",
        "com.apple.TextInputMenuAgent",
        "com.apple.TextInputSwitcher",
        "com.apple.universalcontrol",
        "com.apple.wallpaper.agent",
        "com.apple.ScreenContinuity",
        "com.apple.accessibility.AccessibilityVisualsAgent",
        "com.apple.ViewBridgeAuxiliary",
        "com.apple.AirPlayUIAgent",
        "com.apple.chronod",
        "com.apple.CoreLocationAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.PowerChime",
    ]

    static let ollamaBundleIDs: Set<String> = [
        "com.electron.ollama",
        "com.ollama.ollama",
        "ai.ollama.ollama",
    ]

    /// Path prefixes that indicate an OS component rather than a user application.
    static let protectedPathPrefixes = [
        "/System/Library/",
        "/Library/Apple/",
        "/usr/",
        "/sbin/",
        "/bin/",
    ]

    var ownBundleIdentifier: String?
    var ownPID: Int32
    var userExcludedBundleIDs: Set<String>
    var includeMenuBarApps: Bool
    /// PIDs of apps that are ancestors of the running Ollama server (e.g. a Terminal running `ollama serve`).
    var ollamaHostPIDs: Set<Int32> = []

    func decision(for app: AppDescriptor) -> CloseDecision {
        if app.pid == ownPID || (app.bundleIdentifier != nil && app.bundleIdentifier == ownBundleIdentifier) {
            return .protected(reason: "Local AI Mode")
        }
        if let id = app.bundleIdentifier, Self.ollamaBundleIDs.contains(id) {
            return .protected(reason: "Ollama")
        }
        if app.name.lowercased().contains("ollama") || (app.bundlePath?.lowercased().contains("/ollama") ?? false) {
            return .protected(reason: "Ollama")
        }
        if ollamaHostPIDs.contains(app.pid) {
            return .protected(reason: "Hosts the Ollama server")
        }
        if let id = app.bundleIdentifier, Self.systemBundleIDs.contains(id) {
            return .protected(reason: id == "com.apple.finder" ? "Finder" : "macOS system process")
        }
        if let path = app.bundlePath, Self.protectedPathPrefixes.contains(where: { path.hasPrefix($0) }) {
            return .protected(reason: "macOS system process")
        }
        if app.bundleIdentifier == nil || app.bundlePath == nil {
            return .protected(reason: "No bundle (cannot be safely reopened)")
        }
        if app.activationPolicy == .prohibited {
            return .protected(reason: "Background process")
        }
        if let id = app.bundleIdentifier, userExcludedBundleIDs.contains(id) {
            return .userExcluded
        }
        if app.activationPolicy == .accessory && !includeMenuBarApps {
            return .notIncluded(reason: "Menu-bar app (not included)")
        }
        return .willClose
    }
}
