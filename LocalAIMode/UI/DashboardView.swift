import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case applications = "Applications"
    case ollama = "Ollama"
    case activity = "Activity"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .applications: return "square.grid.2x2"
        case .ollama: return "cpu"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var controller: ModeController
    @State private var section: DashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                StatusPill(text: controller.state.isAIModeOn ? "AI Mode" : "Normal",
                           color: controller.state == .active ? .purple : .secondary)
                    .padding(10)
            }
        } detail: {
            Group {
                switch section ?? .overview {
                case .overview: OverviewView()
                case .applications: ApplicationsPanel()
                case .ollama: OllamaPanel()
                case .activity: ActivityLogView()
                }
            }
            .frame(minWidth: 560)
        }
        .liveMetrics(controller.monitor)
        .sheet(isPresented: Binding(
            get: { controller.state == .awaitingConfirmation },
            set: { if !$0 && controller.state == .awaitingConfirmation { controller.cancelActivation() } })) {
            ConfirmationSheet().environmentObject(controller)
        }
        .sheet(isPresented: Binding(
            get: { controller.state == .recoveryNeeded },
            set: { _ in })) {
            RecoveryView().environmentObject(controller)
        }
        .alert("Busy", isPresented: Binding(
            get: { controller.transientNotice != nil },
            set: { if !$0 { controller.transientNotice = nil } })) {
            Button("OK", role: .cancel) { controller.transientNotice = nil }
        } message: {
            Text(controller.transientNotice ?? "")
        }
        .frame(minWidth: 780, minHeight: 600)
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var controller: ModeController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                banners
                metrics
                MemoryChartView(monitor: controller.monitor)
                HStack(alignment: .top, spacing: 16) {
                    BeforeAfterView(before: controller.monitor.beforeSample, after: controller.monitor.afterSample)
                    MemoryBreakdownView(sample: controller.monitor.latest)
                }
            }
            .padding(20)
        }
        .navigationTitle("Local AI Mode")
    }

    private var header: some View {
        Card(padding: 20) {
            HStack(spacing: 24) {
                ModeToggleButton(state: controller.state) { controller.toggle() }
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.state == .active ? "ON" : (controller.state.isTransitioning ? "" : "OFF"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(controller.state == .active ? .purple : .secondary)
                    Text(controller.state.title)
                        .font(.title.weight(.semibold))
                        .contentTransition(.opacity)
                    if let detail = controller.stepDetail {
                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if controller.state == .normal {
                            Button("Enable AI Mode") { controller.requestActivation() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        } else if controller.state == .active {
                            Button("Disable AI Mode") { controller.requestDeactivation() }
                                .controlSize(.large)
                        }
                        if case .activating(.loadingModel) = controller.state {
                            Button("Cancel Model Load") { controller.cancelModelLoad() }
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controller.state)
    }

    private var subtitle: String {
        switch controller.state {
        case .active:
            return "Model: \(controller.ollama.modelStatus.label)"
        case .normal:
            let n = controller.apps.appsToClose.count
            let model = controller.settings.settings.selectedModel ?? "no model selected"
            return "\(n) app\(n == 1 ? "" : "s") would close · \(model)"
        default:
            return ""
        }
    }

    @ViewBuilder
    private var banners: some View {
        if !controller.stillRunning.isEmpty {
            StillRunningView()
        }
        if !controller.apps.launchedDuringAIMode.isEmpty && controller.state == .active {
            LaunchedDuringAIModeView()
        }
        if case .restorePending(let j) = controller.recovery, controller.state == .normal {
            Banner(symbol: "arrow.uturn.backward.circle.fill", tint: .blue, title: "Workspace not restored",
                   message: "\(j.snapshot.applications.count) app(s) from your last AI Mode session are waiting to be reopened.",
                   actions: AnyView(Button("Restore Workspace") { controller.restorePendingWorkspace() }))
        }
        if case .lost(let model, let reason) = controller.ollama.modelStatus, controller.state == .active {
            Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, title: reason,
                   message: "\(model) is no longer loaded.",
                   actions: AnyView(Button("Reload \(model)") { controller.loadSelectedModel() }))
        }
        if case .failed(let model, let message) = controller.ollama.modelStatus {
            Banner(symbol: "xmark.octagon.fill", tint: .red, title: "\(model) could not be loaded", message: message,
                   actions: AnyView(HStack {
                       Button("Retry") { controller.loadSelectedModel() }
                       Button("Dismiss") { controller.ollama.modelStatus = .idle }
                   }))
        }
        if let report = controller.lastRestoreReport, !report.failures.isEmpty, controller.state == .normal {
            Banner(symbol: "exclamationmark.bubble.fill", tint: .orange, title: "Some items could not be restored",
                   message: report.failures.map { "• \($0.appName): \($0.reason)" }.joined(separator: "\n"))
        }
        if controller.monitor.thermal == .serious || controller.monitor.thermal == .critical {
            Banner(symbol: "thermometer.high", tint: .red, title: "Thermal state: \(controller.monitor.thermal.label)",
                   message: "macOS is limiting performance to protect the hardware. Local AI Mode never overrides this; inference will be slower until the Mac cools down.")
        }
    }

    private var metrics: some View {
        let m = controller.monitor.latest
        let total = m?.totalBytes ?? ProcessInfo.processInfo.physicalMemory
        let ollama = controller.ollama
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            MetricCard(title: "Unified Memory", value: ByteFormat.string(total),
                       detail: m.map { "\(ByteFormat.string($0.availableBytes)) available" },
                       symbol: "memorychip", tint: .blue)
            MetricCard(title: "Memory Used", value: m.map { ByteFormat.string($0.usedBytes) } ?? "—",
                       detail: m.map { "Cached (reclaimable): \(ByteFormat.string($0.cachedBytes))" },
                       symbol: "chart.bar.fill", tint: .blue,
                       fraction: m.map { Double($0.usedBytes) / Double(max(total, 1)) })
            MetricCard(title: "Memory Pressure", value: m?.pressure.label ?? "—",
                       detail: "Reported by the kernel",
                       symbol: "gauge.with.needle", tint: m?.pressure.color ?? .secondary)
            MetricCard(title: "Swap Used", value: m.map { ByteFormat.string($0.swapUsedBytes) } ?? "—",
                       detail: m.map { $0.swapTotalBytes > 0 ? "of \(ByteFormat.string($0.swapTotalBytes)) swap files" : "No swap in use" },
                       symbol: "arrow.left.arrow.right.square", tint: (m?.swapUsedBytes ?? 0) > 1_073_741_824 ? .orange : .teal)
            MetricCard(title: "Ollama Memory",
                       value: ollama.totalReportedBytes > 0 ? ByteFormat.string(UInt64(ollama.totalReportedBytes)) : "—",
                       detail: ollama.measuredFootprintBytes.map { "Process footprint: \(ByteFormat.string($0))" }
                           ?? (ollama.isReachable ? "Reported by /api/ps" : "Ollama not running"),
                       symbol: "brain", tint: .purple)
            MetricCard(title: "Loaded Model",
                       value: ollama.runningModels.first?.name ?? "None",
                       detail: ollama.modelStatus.label,
                       symbol: "shippingbox", tint: .purple)
            MetricCard(title: "CPU", value: controller.monitor.cpu.map { "\(Int(($0.usage * 100).rounded()))%" } ?? "—",
                       detail: controller.monitor.cpu.map { String(format: "User %.0f%% · System %.0f%%", $0.userFraction * 100, $0.systemFraction * 100) },
                       symbol: "cpu", tint: .green, fraction: controller.monitor.cpu?.usage)
            MetricCard(title: "Thermal State", value: controller.monitor.thermal.label,
                       detail: controller.monitor.lowPowerModeEnabled ? "Low Power Mode is on" : "Low Power Mode is off",
                       symbol: "thermometer.medium", tint: controller.monitor.thermal.color)
        }
    }
}

struct MemoryBreakdownView: View {
    var sample: MemorySample?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("What macOS can and can't free").font(.headline)
                if let s = sample {
                    row("App memory", s.appBytes, "Freed only when apps quit", .blue)
                    row("Wired", s.wiredBytes, "Kernel & GPU — never reclaimable by apps", .orange)
                    row("Compressed", s.compressedBytes, "Shrinks as apps quit", .pink)
                    row("Cached files", s.cachedBytes, "Reclaimed automatically on demand", .gray)
                    row("Free", s.freeBytes, "Unused right now", .green)
                }
                Text("macOS does not let any app reserve memory exclusively. AI Mode frees memory by quitting apps; the model then uses what is available.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
    }

    private func row(_ label: String, _ bytes: UInt64, _ note: String, _ color: Color) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.callout)
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(bytes)).font(.callout.monospacedDigit())
        }
    }
}

// MARK: - Still running / launched during AI Mode

struct StillRunningView: View {
    @EnvironmentObject var controller: ModeController
    @State private var forceQuitTarget: AppSnapshotEntry?

    var body: some View {
        Banner(symbol: "hourglass", tint: .orange, title: "Some apps haven't quit",
               message: "They may be waiting for you to save documents. Switch to them to respond, wait longer, or leave them open.",
               actions: AnyView(VStack(alignment: .leading, spacing: 6) {
                   ForEach(controller.stillRunning) { entry in
                       HStack {
                           Text(entry.name).font(.callout.weight(.medium))
                           Spacer()
                           Button("Show") {
                               NSRunningApplication(processIdentifier: entry.processIdentifier)?.activate()
                           }
                           Button("Wait Longer") { controller.waitLonger(for: entry) }
                           Button("Keep Open") { controller.keepOpen(entry) }
                           Button("Force Quit…", role: .destructive) { forceQuitTarget = entry }
                       }
                       .controlSize(.small)
                   }
               }))
        .confirmationDialog("Force quit \(forceQuitTarget?.name ?? "")?",
                            isPresented: Binding(get: { forceQuitTarget != nil }, set: { if !$0 { forceQuitTarget = nil } }),
                            presenting: forceQuitTarget) { entry in
            Button("Force Quit", role: .destructive) { controller.forceQuit(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Any unsaved changes in this app will be lost. Use this only for apps that are not responding.")
        }
    }
}

struct LaunchedDuringAIModeView: View {
    @EnvironmentObject var controller: ModeController

    var body: some View {
        Banner(symbol: "plus.app", tint: .blue, title: "Apps opened during AI Mode",
               message: "These use memory the model could use. They won't be closed automatically.",
               actions: AnyView(VStack(alignment: .leading, spacing: 6) {
                   ForEach(controller.apps.launchedDuringAIMode) { app in
                       HStack {
                           if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                           Text(app.name).font(.callout)
                           Spacer()
                           Button("Quit") { controller.quitLaunchedApp(app) }.controlSize(.small)
                       }
                   }
               }))
    }
}

// MARK: - Activity log

struct ActivityLogView: View {
    @EnvironmentObject var controller: ModeController

    var body: some View {
        List(controller.log) { event in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: event.kind.symbol).foregroundStyle(event.kind.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.message).textSelection(.enabled)
                    Text(event.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if controller.log.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Steps taken by AI Mode will appear here."))
            }
        }
        .navigationTitle("Activity")
    }
}
