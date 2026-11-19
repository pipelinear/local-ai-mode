import SwiftUI

struct ApplicationsPanel: View {
    @EnvironmentObject var controller: ModeController
    @State private var showMenuBarApps = false

    private var visibleApps: [RunningAppInfo] {
        controller.apps.apps.filter { showMenuBarApps || $0.policy == .regular }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(controller.apps.appsToClose.count) of \(controller.apps.apps.count) apps will close")
                        .font(.headline)
                    Text("Approximately \(ByteFormat.string(controller.apps.estimatedReclaimableBytes)) of app memory (includes helper processes)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show menu-bar apps", isOn: $showMenuBarApps).toggleStyle(.switch).controlSize(.small)
            }
            .padding()
            Divider()
            Table(visibleApps) {
                TableColumn("Application") { app in
                    HStack(spacing: 8) {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.name)
                            if app.policy == .accessory {
                                Text("Menu-bar app").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .width(min: 180, ideal: 240)
                TableColumn("Memory") { app in
                    Text(app.memoryBytes.map(ByteFormat.string) ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(app.memoryBytes == nil ? .secondary : .primary)
                }
                .width(80)
                TableColumn("On Activation") { app in
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: app.decision))
                            .foregroundStyle(color(for: app.decision))
                        Text(app.decision.label).font(.callout)
                    }
                }
                .width(min: 150, ideal: 190)
                TableColumn("Exclude") { app in
                    if let id = app.bundleIdentifier, !app.decision.isProtected {
                        Toggle("", isOn: Binding(
                            get: { controller.settings.settings.userExcludedBundleIDs.contains(id) },
                            set: { controller.settings.setExcluded(id, excluded: $0) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    } else {
                        Image(systemName: "lock.fill").foregroundStyle(.tertiary).help("Protected — always kept running")
                    }
                }
                .width(60)
            }
        }
        .navigationTitle("Applications")
        .onAppear {
            controller.apps.refresh()
            controller.apps.refreshMemory()
        }
    }

    private func icon(for d: CloseDecision) -> String {
        switch d {
        case .willClose: return "xmark.circle.fill"
        case .userExcluded: return "hand.raised.fill"
        case .protected: return "lock.shield.fill"
        case .notIncluded: return "minus.circle"
        }
    }

    private func color(for d: CloseDecision) -> Color {
        switch d {
        case .willClose: return .orange
        case .userExcluded: return .blue
        case .protected: return .green
        case .notIncluded: return .secondary
        }
    }
}

/// Shown before activation: pick which apps close and confirm the model.
struct ConfirmationSheet: View {
    @EnvironmentObject var controller: ModeController

    private var candidates: [RunningAppInfo] { controller.apps.apps.filter { $0.decision.willClose } }
    private var selectedBytes: UInt64 {
        candidates.filter { controller.selectedPIDs.contains($0.pid) }.reduce(0) { $0 &+ ($1.memoryBytes ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.circle.fill").font(.system(size: 34)).foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text(controller.machine.isResuming ? "Resume AI Mode" : "Enable AI Mode").font(.title2.weight(.semibold))
                    Text("These apps will be asked to quit. Each app can still ask you to save changes. Nothing is force-quit.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if candidates.isEmpty {
                ContentUnavailableView("No Apps to Close", systemImage: "checkmark.circle",
                                       description: Text("Only protected or excluded apps are running."))
                    .frame(height: 160)
            } else {
                List {
                    ForEach(candidates) { app in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { controller.selectedPIDs.contains(app.pid) },
                                set: { on in
                                    if on { controller.selectedPIDs.insert(app.pid) } else { controller.selectedPIDs.remove(app.pid) }
                                })) {
                                HStack(spacing: 8) {
                                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                                    Text(app.name)
                                }
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Text(app.memoryBytes.map(ByteFormat.string) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                            if let id = app.bundleIdentifier {
                                Button("Always Keep") {
                                    controller.settings.setExcluded(id, excluded: true)
                                    controller.selectedPIDs.remove(app.pid)
                                }
                                .controlSize(.small)
                                .help("Add to the permanent exclusion list")
                            }
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 320)
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                Text("Unchecked apps stay open this time only. Estimated app memory freed: \(ByteFormat.string(selectedBytes)).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            ModelPickerRow()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { controller.cancelActivation() }
                    .keyboardShortcut(.cancelAction)
                Button(controller.machine.isResuming ? "Resume" : "Enable AI Mode") { controller.confirmActivation() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct ModelPickerRow: View {
    @EnvironmentObject var controller: ModeController

    var body: some View {
        let ollama = controller.ollama
        HStack {
            Label("Model", systemImage: "shippingbox").font(.callout.weight(.medium))
            Spacer()
            if ollama.installedModels.isEmpty {
                Text(ollama.isReachable ? "No models installed" : "Ollama not running — it will be started")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: Binding(
                    get: { controller.settings.settings.selectedModel ?? "" },
                    set: { controller.settings.settings.selectedModel = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(ollama.installedModels) { m in
                        Text("\(m.name)  (\(ByteFormat.string(UInt64(m.size))))").tag(m.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }
        }
    }
}
