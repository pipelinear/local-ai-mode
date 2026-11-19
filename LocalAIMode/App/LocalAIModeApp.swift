import SwiftUI

/// Holds the single controller so the AppDelegate can consult mode state on quit.
@MainActor
enum AppContainer {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static let controller: ModeController = {
        if isRunningTests {
            // Unit tests are hosted by the app; keep the host inert and isolated from real session data.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAIModeTestHost-\(UUID().uuidString)")
            return ModeController(settings: SettingsManager(defaults: UserDefaults(suiteName: "LocalAIModeTestHost") ?? .standard),
                                  store: SessionStore(directory: dir), startMonitoring: false)
        }
        let c = ModeController()
        c.assessRecoveryAtLaunch()
        return c
    }()
}

@main
struct LocalAIModeApp: App {
    static let dashboardWindowID = "dashboard"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppContainer.controller

    private var launchBehavior: SceneLaunchBehavior {
        if AppContainer.isRunningTests { return .suppressed }
        let s = controller.settings.settings
        let minimized = s.startMinimized && s.showInMenuBar && controller.state != .recoveryNeeded
        return minimized ? .suppressed : .presented
    }

    var body: some Scene {
        Window("Local AI Mode", id: Self.dashboardWindowID) {
            DashboardView()
                .environmentObject(controller)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear {
                    // Menu-bar-first: drop the Dock icon when the dashboard closes (if the menu-bar icon is shown).
                    if controller.settings.settings.showInMenuBar { NSApp.setActivationPolicy(.accessory) }
                }
        }
        .defaultLaunchBehavior(launchBehavior)
        .defaultSize(width: 980, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(controller.state == .active ? "Disable AI Mode" : "Enable AI Mode") { controller.toggle() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(controller.state.isTransitioning || controller.state == .recoveryNeeded)
            }
        }

        Settings {
            SettingsView().environmentObject(controller)
        }

        MenuBarExtra(isInserted: Binding(
            get: { controller.settings.settings.showInMenuBar && !AppContainer.isRunningTests },
            set: { controller.settings.settings.showInMenuBar = $0 })) {
            MenuBarView().environmentObject(controller)
        } label: {
            MenuBarIcon(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppContainer.isRunningTests else { return }
        let s = AppContainer.controller.settings.settings
        if s.startMinimized && s.showInMenuBar && AppContainer.controller.state != .recoveryNeeded {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Menu-bar-first app: closing the dashboard (or having no windows, as in the test host) must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true // SwiftUI reopens the dashboard Window scene
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = AppContainer.controller
        let state = controller.state
        guard state == .active || state.isTransitioning else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if state.isTransitioning {
            alert.messageText = "AI Mode is changing state"
            alert.informativeText = "Quitting now leaves the transition unfinished. Your workspace snapshot is saved, and Local AI Mode will offer to restore it the next time it opens."
        } else {
            alert.messageText = "AI Mode is on"
            alert.informativeText = "If you quit, the model stays loaded and your apps stay closed. Next time Local AI Mode opens it will offer to restore your workspace or resume AI Mode."
        }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
