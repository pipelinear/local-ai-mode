import AppKit
import ApplicationServices

// MARK: - Restore planning (pure, testable)

protocol AppEnvironment {
    func fileExists(atPath path: String) -> Bool
    func applicationURL(forBundleIdentifier id: String) -> URL?
    func isRunning(bundleIdentifier: String?, bundlePath: String) -> Bool
}

enum RestoreAction: Equatable {
    case launch(AppSnapshotEntry, url: URL, relocated: Bool)
    case alreadyRunning(AppSnapshotEntry)
    case missing(AppSnapshotEntry, reason: String)

    var entry: AppSnapshotEntry {
        switch self {
        case .launch(let e, _, _), .alreadyRunning(let e), .missing(let e, _): return e
        }
    }
}

enum RestorePlanner {
    /// Every app in the snapshot that is not running now gets relaunched, in original launch order.
    /// Moved apps are found again through Launch Services by bundle identifier.
    static func plan(for snapshot: WorkspaceSnapshot, environment env: AppEnvironment) -> [RestoreAction] {
        snapshot.applications
            .sorted { $0.launchOrder < $1.launchOrder }
            .map { entry in
                if env.isRunning(bundleIdentifier: entry.bundleIdentifier, bundlePath: entry.bundlePath) {
                    return .alreadyRunning(entry)
                }
                if env.fileExists(atPath: entry.bundlePath) {
                    return .launch(entry, url: URL(fileURLWithPath: entry.bundlePath), relocated: false)
                }
                if let id = entry.bundleIdentifier, let url = env.applicationURL(forBundleIdentifier: id),
                   env.fileExists(atPath: url.path) {
                    return .launch(entry, url: url, relocated: true)
                }
                return .missing(entry, reason: "Application not found at \(entry.bundlePath) — it may have been moved or uninstalled")
            }
    }

    /// Documents that still exist on disk.
    static func existingDocuments(for entry: AppSnapshotEntry, environment env: AppEnvironment) -> [URL] {
        entry.documentURLs.compactMap { URL(string: $0) }
            .filter { $0.isFileURL && env.fileExists(atPath: $0.path) }
    }
}

struct SystemAppEnvironment: AppEnvironment {
    func fileExists(atPath path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func applicationURL(forBundleIdentifier id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }
    func isRunning(bundleIdentifier: String?, bundlePath: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard !app.isTerminated else { return false }
            if let id = bundleIdentifier, app.bundleIdentifier == id { return true }
            return app.bundleURL?.path == bundlePath
        }
    }
}

// MARK: - Browser tab capture (optional, Apple Events)

enum BrowserBridge {
    enum Flavor { case safari, chromium }

    static let supported: [String: Flavor] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "company.thebrowser.Browser": .chromium, // Arc
        "com.vivaldi.Vivaldi": .chromium,
    ]

    static func isSupported(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return supported[bundleID] != nil
    }

    /// Runs only against browsers that are already running. Returns nil if permission is denied or the script fails.
    static func captureTabs(bundleID: String) -> [BrowserTab]? {
        guard let flavor = supported[bundleID] else { return nil }
        let titleProp = flavor == .safari ? "name" : "title"
        let urlProp = flavor == .safari ? "URL" : "URL"
        let source = """
        set out to ""
        tell application id "\(bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set out to out & (\(urlProp) of t) & tab & (\(titleProp) of t) & linefeed
                    end try
                end repeat
            end repeat
        end tell
        return out
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let text = result.stringValue ?? ""
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let url = parts.first.map(String.init), url.hasPrefix("http") || url.hasPrefix("file:") else { return nil }
            return BrowserTab(url: url, title: parts.count > 1 ? String(parts[1]) : nil)
        }
    }

    static func windowCount(bundleID: String) -> Int? {
        let source = "tell application id \"\(bundleID)\" to count windows"
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return Int(result.int32Value)
    }
}

// MARK: - Accessibility (optional) for open documents

enum AccessibilityBridge {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Reads `AXDocument` from each window. Bounded by a 1-second messaging timeout per app so a hung app can't stall us.
    static func documentsAndWindowCount(pid: pid_t) -> (documents: [String], windows: Int)? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var docs: [String] = []
        for window in windows {
            var doc: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &doc) == .success,
               let s = doc as? String, s.hasPrefix("file://"), !docs.contains(s) {
                docs.append(s)
            }
        }
        return (docs, windows.count)
    }
}

// MARK: - Workspace manager

@MainActor
final class WorkspaceManager {
    private let environment: AppEnvironment

    init(environment: AppEnvironment = SystemAppEnvironment()) {
        self.environment = environment
    }

    /// Records every app that will be closed plus all other user-visible apps, so restore knows the full picture.
    func captureSnapshot(apps: [RunningAppInfo], captureDocuments: Bool, captureBrowserTabs: Bool,
                         progress: @escaping (String) -> Void) async -> WorkspaceSnapshot {
        let candidates = apps.filter { $0.decision.willClose }
        // Order by launch date so relaunching recreates a familiar Dock/app-switcher order.
        let ordered = candidates.sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        let axTrusted = captureDocuments && AccessibilityBridge.isTrusted

        var entries: [AppSnapshotEntry] = []
        for (index, app) in ordered.enumerated() {
            guard let path = app.bundlePath else { continue }
            var entry = AppSnapshotEntry(name: app.name, bundleIdentifier: app.bundleIdentifier, bundlePath: path,
                                         processIdentifier: app.pid, wasHidden: app.isHidden, wasActive: app.isActive,
                                         launchOrder: index)
            if axTrusted {
                progress("Reading windows of \(app.name)")
                let pid = app.pid
                let result = await Task.detached(priority: .userInitiated) {
                    AccessibilityBridge.documentsAndWindowCount(pid: pid)
                }.value
                if let result {
                    entry.documentURLs = result.documents
                    entry.windowCount = result.windows
                }
            }
            if captureBrowserTabs, let id = app.bundleIdentifier, BrowserBridge.isSupported(id) {
                progress("Recording tabs in \(app.name)")
                entry.browserTabs = await Task.detached(priority: .userInitiated) {
                    BrowserBridge.captureTabs(bundleID: id) ?? []
                }.value
            }
            entries.append(entry)
        }
        return WorkspaceSnapshot(applications: entries, accessibilityWasAvailable: axTrusted,
                                 browserCaptureWasEnabled: captureBrowserTabs)
    }

    /// Relaunches apps and reopens documents/tabs using the best supported method for each.
    func restore(snapshot: WorkspaceSnapshot, progress: @escaping (String) -> Void) async -> RestoreReport {
        var report = RestoreReport()
        let plan = RestorePlanner.plan(for: snapshot, environment: environment)
        var frontmost: NSRunningApplication?

        for action in plan {
            switch action {
            case .alreadyRunning(let entry):
                report.alreadyRunning.append(entry.name)
            case .missing(let entry, let reason):
                report.failures.append(RestoreFailure(appName: entry.name, reason: reason))
            case .launch(let entry, let url, let relocated):
                progress("Opening \(entry.name)")
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = entry.wasHidden
                config.addsToRecentItems = false
                do {
                    let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                    report.reopened.append(entry.name)
                    if relocated { report.relocated.append(entry.name) }
                    if entry.wasActive { frontmost = app }

                    let docs = RestorePlanner.existingDocuments(for: entry, environment: environment)
                    let missingDocs = entry.documentURLs.count - docs.count
                    if !docs.isEmpty {
                        let docConfig = NSWorkspace.OpenConfiguration()
                        docConfig.activates = false
                        _ = try? await NSWorkspace.shared.open(docs, withApplicationAt: url, configuration: docConfig)
                    }
                    if missingDocs > 0 {
                        report.failures.append(RestoreFailure(appName: entry.name,
                                                              reason: "\(missingDocs) document(s) no longer exist"))
                    }
                    if !entry.browserTabs.isEmpty, let id = entry.bundleIdentifier {
                        await restoreTabs(entry: entry, bundleID: id, appURL: url, report: &report)
                    }
                } catch {
                    report.failures.append(RestoreFailure(appName: entry.name,
                                                          reason: "Could not launch: \(error.localizedDescription)"))
                }
            }
        }
        frontmost?.activate()
        return report
    }

    /// Browsers usually restore their own session. Only if one comes back with no windows do we reopen saved tabs.
    private func restoreTabs(entry: AppSnapshotEntry, bundleID: String, appURL: URL, report: inout RestoreReport) async {
        try? await Task.sleep(for: .seconds(3))
        let count = await Task.detached { BrowserBridge.windowCount(bundleID: bundleID) }.value
        guard count == 0 else { return } // browser restored its own windows (or we can't tell — avoid duplicates)
        let urls = entry.browserTabs.compactMap { URL(string: $0.url) }
        guard !urls.isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
        } catch {
            report.failures.append(RestoreFailure(appName: entry.name, reason: "Could not reopen tabs: \(error.localizedDescription)"))
        }
    }
}
