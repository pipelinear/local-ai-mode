import SwiftUI

/// Offered at launch when the previous AI Mode session did not finish. Nothing happens without a choice.
struct RecoveryView: View {
    @EnvironmentObject var controller: ModeController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 40)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Mode Didn't Finish").font(.title2.weight(.semibold))
                    Text("Local AI Mode, the Mac, or Ollama stopped while AI Mode was on. Nothing has been changed since — choose what to do.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let j = controller.journal {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Started", value: j.startedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Stopped during", value: j.phase.rawValue.capitalized)
                        LabeledContent("Apps in snapshot", value: "\(j.snapshot.applications.count)")
                        if let model = j.requestedModel { LabeledContent("Model", value: model) }
                        if j.changedSettings.powerModesChanged {
                            LabeledContent("Power settings", value: "Changed (Low Power Mode off)")
                        }
                        if !j.snapshot.applications.isEmpty {
                            Text(j.snapshot.applications.map(\.name).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    controller.restorePreviousWorkspace()
                } label: {
                    Label("Restore Previous Workspace", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Unloads models, restores power settings and reopens the apps from your snapshot.")
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    controller.resumeAIMode()
                } label: {
                    Label("Resume AI Mode", systemImage: "bolt")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text("Shows the apps that would close, then reloads the model. Your original snapshot is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Discard Session") { controller.dismissRecovery() }
                    .buttonStyle(.link)
                    .help("Forget this session. The snapshot stays available under Settings › Emergency Restore.")
            }
        }
        .padding(22)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}
