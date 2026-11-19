import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: ModeController

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ApplicationSettings().tabItem { Label("Applications", systemImage: "square.grid.2x2") }
            OllamaSettings().tabItem { Label("Ollama", systemImage: "cpu") }
            PowerSettings().tabItem { Label("Power", systemImage: "bolt") }
            RecoverySettings().tabItem { Label("Recovery", systemImage: "lifepreserver") }
        }
        .frame(width: 560, height: 470)
        .environmentObject(controller)
    }
}

private extension View {
    func settingsForm() -> some View { formStyle(.grouped).scrollContentBackground(.hidden) }
}

struct GeneralSettings: View {
    @EnvironmentObject var controller: ModeController
    var body: some View {
        let settings = controller.settings
        let b = Binding(get: { settings.settings }, set: { settings.settings = $0 })
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                         set: { settings.setLaunchAtLogin($0) }))
                if let err = settings.launchAtLoginError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show in menu bar", isOn: b.showInMenuBar)
                Toggle("Start minimized (menu bar only)", isOn: b.startMinimized)
                    .disabled(!b.wrappedValue.showInMenuBar)
                    .help("Requires the menu-bar icon so the app stays reachable.")
            }
            Section("When enabling AI Mode") {
                Toggle("Confirm before closing applications", isOn: b.confirmBeforeClosing)
            }
            Section("When disabling AI Mode") {
                Toggle("Restore applications automatically", isOn: b.restoreAppsAutomatically)
                Toggle("Keep Ollama running after exiting AI Mode", isOn: b.keepOllamaRunningAfterExit)
            }
        }
        .settingsForm()
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}

struct ApplicationSettings: View {
    @EnvironmentObject var controller: ModeController
    @State private var selection: String?
    @State private var accessibilityTrusted = AccessibilityBridge.isTrusted

    var body: some View {
        let settings = controller.settings
        let b = Binding(get: { settings.settings }, set: { settings.settings = $0 })
        Form {
            Section("Always keep running") {
                List(selection: $selection) {
                    ForEach(settings.settings.userExcludedBundleIDs, id: \.self) { id in
                        HStack {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                                Text(FileManager.default.displayName(atPath: url.path))
                            } else {
                                Text(id)
                            }
                            Spacer()
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(id)
                    }
                }
                .frame(minHeight: 90)
                HStack {
                    Button("Add Application…") { addApp() }
                    Button("Remove") {
                        if let s = selection { settings.setExcluded(s, excluded: false) }
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                Text("Local AI Mode, Ollama, Finder, macOS system processes and any app hosting the Ollama server are always protected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Closing") {
                Toggle("Also close menu-bar apps", isOn: b.includeMenuBarApps)
                LabeledContent("Wait for apps to quit") {
                    Stepper("\(Int(b.wrappedValue.gracefulQuitTimeout)) s", value: b.gracefulQuitTimeout, in: 5...120, step: 5)
                }
            }
            Section("Restoring") {
                Toggle("Record open documents (Accessibility)", isOn: b.captureDocumentsWithAccessibility)
                if b.wrappedValue.captureDocumentsWithAccessibility && !accessibilityTrusted {
                    HStack {
                        Text("Accessibility permission is needed to read which documents are open. Without it, apps reopen using their own window restoration.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Grant…") {
                            AccessibilityBridge.requestTrust()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { accessibilityTrusted = AccessibilityBridge.isTrusted }
                        }
                    }
                }
                Toggle("Record browser tabs (Automation)", isOn: b.captureBrowserTabs)
                Text("Saves tab URLs from Safari, Chrome, Arc, Brave, Edge and Vivaldi. They are reopened only if the browser doesn't restore its own windows. macOS asks for permission per browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
        .onAppear { accessibilityTrusted = AccessibilityBridge.isTrusted }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { controller.settings.setExcluded(id, excluded: true) }
        }
    }
}

struct OllamaSettings: View {
    @EnvironmentObject var controller: ModeController
    var body: some View {
        let settings = controller.settings
        let b = Binding(get: { settings.settings }, set: { settings.settings = $0 })
        Form {
            Section("Model") {
                ModelPickerRow()
                OllamaRuntimeSettings()
            }
            Section("Server") {
                TextField("API address", text: b.ollamaBaseURL)
                Picker("Start Ollama using", selection: b.launchMethod) {
                    ForEach(OllamaLaunchMethod.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Model load timeout") {
                    Stepper("\(Int(b.wrappedValue.modelLoadTimeout)) s", value: b.modelLoadTimeout, in: 60...1800, step: 60)
                }
                LabeledContent("Unload wait") {
                    Stepper("\(Int(b.wrappedValue.unloadTimeout)) s", value: b.unloadTimeout, in: 10...600, step: 10)
                }
            }
        }
        .settingsForm()
    }
}

struct PowerSettings: View {
    @EnvironmentObject var controller: ModeController
    var body: some View {
        let settings = controller.settings
        let b = Binding(get: { settings.settings }, set: { settings.settings = $0 })
        Form {
            Section {
                LabeledContent("Low Power Mode", value: controller.monitor.lowPowerModeEnabled ? "On" : "Off")
                LabeledContent("Thermal state", value: controller.monitor.thermal.label)
            }
            Section("During AI Mode") {
                Toggle("Turn off Low Power Mode (asks for administrator password)", isOn: b.disableLowPowerMode)
                Toggle("Prevent idle sleep", isOn: b.preventIdleSleep)
                Text("The original Low Power Mode setting is recorded before it is changed and restored when AI Mode ends (another password prompt). Thermal management, memory compression and swap are never modified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
    }
}

struct RecoverySettings: View {
    @EnvironmentObject var controller: ModeController
    @State private var confirm = false

    var body: some View {
        Form {
            Section("Emergency Workspace Restore") {
                Text("Reopens the apps from the current session journal, or from the last completed AI Mode session, and restores power settings if they were changed. Use this if something went wrong.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Restore Workspace Now…") { confirm = true }
                    .disabled(!controller.hasEmergencySnapshot || controller.state.isTransitioning)
                if let report = controller.lastRestoreReport {
                    Text(report.summary).font(.caption)
                }
            }
            Section("Storage") {
                LabeledContent("Session data") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([controller.store.directory]) }
                }
                Text("Snapshots and settings are stored only on this Mac and are never transmitted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
        .confirmationDialog("Restore your saved workspace?", isPresented: $confirm) {
            Button("Restore") { controller.emergencyRestore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps that aren't running will be reopened. AI Mode's state and loaded models are not changed.")
        }
    }
}
