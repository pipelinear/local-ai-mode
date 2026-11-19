import SwiftUI

struct OllamaPanel: View {
    @EnvironmentObject var controller: ModeController
    @State private var restartError: String?

    var body: some View {
        let ollama = controller.ollama
        let s = controller.settings.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard(ollama)

                if let error = ollama.lastError {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Ollama", message: error,
                           actions: AnyView(Button("Dismiss") { ollama.clearError() }))
                }
                if let message = ollama.progressMessage {
                    HStack { ProgressView().controlSize(.small); Text(message).foregroundStyle(.secondary) }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Loaded Models").font(.headline)
                        if ollama.runningModels.isEmpty {
                            Text(ollama.isReachable ? "No models are loaded." : "—").foregroundStyle(.secondary)
                        }
                        ForEach(ollama.runningModels) { m in
                            HStack(alignment: .top) {
                                Image(systemName: "shippingbox.fill").foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(m.name).font(.body.weight(.medium))
                                    Text("Reported by Ollama: \(ByteFormat.string(UInt64(m.size))) · \(Int((m.gpuFraction * 100).rounded()))% on GPU"
                                         + (m.context_length.map { " · context \($0)" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(m.neverExpires ? "Keep-alive: indefinitely"
                                         : (m.expiresAt.map { "Unloads \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        if let fp = ollama.measuredFootprintBytes {
                            Divider()
                            Text("Measured footprint of all ollama processes: \(ByteFormat.string(fp))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Load Selected Model") { controller.loadSelectedModel() }
                                .disabled(s.selectedModel == nil || controller.state.isTransitioning)
                            if case .loading = ollama.modelStatus {
                                Button("Cancel") { controller.cancelModelLoad() }
                            }
                            Button("Unload All") { controller.unloadAllModels() }
                                .disabled(ollama.runningModels.isEmpty || controller.state.isTransitioning)
                        }
                        .padding(.top, 4)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Installed Models").font(.headline)
                            Spacer()
                            Button { Task { await ollama.refresh(includeInstalled: true) } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh")
                        }
                        if ollama.installedModels.isEmpty {
                            Text(ollama.isReachable ? "No models installed. Use `ollama pull <model>` once to download one." : "Start Ollama to list models.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(ollama.installedModels) { m in
                            ModelRow(model: m, selected: s.selectedModel == m.name,
                                     loaded: ollama.runningModels.contains { $0.name == m.name },
                                     estimate: ollama.estimates[m.name])
                                .contentShape(Rectangle())
                                .onTapGesture { controller.settings.settings.selectedModel = m.name }
                                .task(id: "\(m.name)-\(s.contextLength)-\(s.kvCacheType.rawValue)") {
                                    await ollama.estimate(for: m, contextLength: s.contextLength, kvType: s.kvCacheType)
                                }
                        }
                        Text("Estimated = model file size + KV cache for the configured context. “Reported” figures come from Ollama's /api/ps after loading and are authoritative.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Runtime").font(.headline)
                        OllamaRuntimeSettings()
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Server settings (parallel requests, loaded models, flash attention, KV cache type) only apply when Local AI Mode starts `ollama serve`.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let restartError { Text(restartError).font(.caption).foregroundStyle(.red) }
                            }
                            Spacer()
                            Button("Restart Ollama with These Settings") {
                                restartError = nil
                                Task {
                                    do {
                                        try await ollama.restartWithServerSettings(controller.settings.settings)
                                        controller.settings.settings.launchMethod = .serve
                                        controller.record("Ollama restarted with server settings.", .success)
                                    } catch {
                                        restartError = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(controller.state.isTransitioning || !ollama.isInstalled)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Ollama")
        .task { await ollama.refresh(includeInstalled: true, measureFootprint: true) }
    }

    private func statusCard(_ ollama: OllamaService) -> some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: ollama.isReachable ? "checkmark.circle.fill" : (ollama.isInstalled ? "pause.circle.fill" : "xmark.circle.fill"))
                    .font(.title)
                    .foregroundStyle(ollama.isReachable ? .green : (ollama.isInstalled ? .orange : .red))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ollama.isReachable ? "Ollama \(ollama.version ?? "") is running"
                         : (ollama.isInstalled ? "Ollama is installed but not running" : "Ollama is not installed"))
                        .font(.headline)
                    Text(controller.settings.settings.ollamaBaseURL).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !ollama.isReachable && ollama.isInstalled {
                    Button("Start Ollama") {
                        Task {
                            do { _ = try await ollama.ensureRunning(settings: controller.settings.settings) }
                            catch { controller.record(error.localizedDescription, .error) }
                        }
                    }
                } else if !ollama.isInstalled {
                    Link("Get Ollama", destination: URL(string: "https://ollama.com/download")!)
                }
            }
        }
    }
}

struct ModelRow: View {
    var model: OllamaModel
    var selected: Bool
    var loaded: Bool
    var estimate: (total: Int64, kvCache: Int64?)?

    var body: some View {
        HStack {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).font(.body.weight(selected ? .semibold : .regular))
                    if loaded { StatusPill(text: "Loaded", color: .green) }
                }
                Text([model.details?.family, model.details?.parameter_size, model.details?.quantization_level]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("File \(ByteFormat.string(UInt64(model.size)))").font(.caption.monospacedDigit())
                if let estimate {
                    Text("Est. \(ByteFormat.string(UInt64(estimate.total)))"
                         + (estimate.kvCache.map { " (KV \(ByteFormat.string(UInt64($0))))" } ?? ""))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Shared between the Ollama panel and Settings.
struct OllamaRuntimeSettings: View {
    @EnvironmentObject var controller: ModeController

    var body: some View {
        let binding = Binding(get: { controller.settings.settings }, set: { controller.settings.settings = $0 })
        Form {
            Picker("Keep model loaded", selection: binding.keepAliveMinutes) {
                Text("Indefinitely").tag(-1)
                Text("5 minutes").tag(5)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("4 hours").tag(240)
                Text("24 hours").tag(1440)
            }
            Picker("Context window", selection: binding.contextLength) {
                Text("Model default").tag(0)
                ForEach([2048, 4096, 8192, 16384, 32768, 65536, 131072], id: \.self) { Text("\($0) tokens").tag($0) }
            }
            Stepper("Parallel requests: \(binding.wrappedValue.numParallel)", value: binding.numParallel, in: 1...8)
            Stepper("Max loaded models: \(binding.wrappedValue.maxLoadedModels)", value: binding.maxLoadedModels, in: 1...4)
            Toggle("Flash attention", isOn: binding.flashAttention)
            Picker("KV cache type", selection: binding.kvCacheType) {
                Text("f16 (default)").tag(KVCacheType.f16)
                Text("q8_0 (≈½ memory)").tag(KVCacheType.q8_0)
                Text("q4_0 (≈¼ memory)").tag(KVCacheType.q4_0)
            }
            .disabled(!binding.wrappedValue.flashAttention)
        }
        .formStyle(.columns)
    }
}
