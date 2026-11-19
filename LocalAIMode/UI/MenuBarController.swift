import SwiftUI

/// Compact panel shown from the menu-bar icon (SwiftUI `MenuBarExtra`, the native status-item API).
struct MenuBarView: View {
    @EnvironmentObject var controller: ModeController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = controller.state
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: state == .active ? "bolt.circle.fill" : "power.circle")
                    .font(.title2)
                    .foregroundStyle(state == .active ? .purple : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Local AI Mode").font(.headline)
                    Text(state.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.isAIModeOn },
                    set: { _ in handleToggle() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(state.isTransitioning || state == .awaitingConfirmation || state == .recoveryNeeded)
            }

            if let detail = controller.stepDetail, state.isTransitioning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Divider()

            row("Model", controller.ollama.runningModels.first?.name ?? controller.settings.settings.selectedModel ?? "None",
                detail: controller.ollama.modelStatus.label)
            HStack {
                Text("Memory pressure").font(.callout)
                Spacer()
                let p = controller.monitor.latest?.pressure ?? .unknown
                StatusPill(text: p.label, color: p.color)
            }
            if let m = controller.monitor.latest {
                ProgressView(value: Double(m.usedBytes), total: Double(max(m.totalBytes, 1))) {
                    Text("\(ByteFormat.string(m.usedBytes)) of \(ByteFormat.string(m.totalBytes)) used")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tint(m.pressure.color)
            }
            if !controller.stillRunning.isEmpty {
                Label("\(controller.stillRunning.count) app(s) haven't quit", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                menuButton("Open Dashboard", "macwindow") { openDashboard() }
                menuButton("Restore Workspace", "arrow.uturn.backward") {
                    if case .restorePending = controller.recovery { controller.restorePendingWorkspace() }
                    else if state == .recoveryNeeded { openDashboard() }
                    else { controller.emergencyRestore() }
                }
                .disabled(!controller.hasEmergencySnapshot || state.isTransitioning)
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuRowButtonStyle())
                menuButton("Quit Local AI Mode", "power") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .liveMetrics(controller.monitor)
    }

    private func handleToggle() {
        // Confirmation (if enabled) and recovery are shown in the dashboard window.
        if controller.state == .normal && controller.settings.settings.confirmBeforeClosing { openDashboard() }
        controller.toggle()
    }

    private func openDashboard() {
        openWindow(id: LocalAIModeApp.dashboardWindowID)
        NSApp.activate()
    }

    private func row(_ title: String, _ value: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.callout)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(value).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func menuButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct MenuRow<Label: View>: View {
        var label: Label
        var isPressed: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isPressed ? Color.accentColor.opacity(0.3) : (hovering && isEnabled ? Color.primary.opacity(0.08) : .clear)))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Menu-bar icon reflecting the current mode.
struct MenuBarIcon: View {
    @ObservedObject var controller: ModeController
    var body: some View {
        Image(systemName: controller.state == .active ? "bolt.circle.fill"
              : (controller.state.isTransitioning ? "circle.dotted" : "bolt.circle"))
    }
}
