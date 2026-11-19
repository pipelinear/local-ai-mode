import AppKit
import Combine

/// Locates and starts/stops Ollama using supported mechanisms only (Launch Services or the `ollama serve` CLI).
@MainActor
final class OllamaLauncher {
    static let appBundleIDs = ["com.electron.ollama", "com.ollama.ollama", "ai.ollama.ollama"]

    private(set) var serveProcess: Process?
    private(set) var logURL = SessionStore.defaultDirectory().appendingPathComponent("ollama-serve.log")

    var appURL: URL? {
        for id in Self.appBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let fallback = URL(fileURLWithPath: "/Applications/Ollama.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    var cliURL: URL? {
        var candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
        if let app = appURL { candidates.append(app.appendingPathComponent("Contents/Resources/ollama").path) }
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var isInstalled: Bool { appURL != nil || cliURL != nil }

    var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard let id = app.bundleIdentifier else { return false }
            return Self.appBundleIDs.contains(id) && !app.isTerminated
        }
    }

    var isServeProcessOurs: Bool { serveProcess?.isRunning ?? false }

    /// Starts Ollama. Returns a description of how it was started.
    func start(method: OllamaLaunchMethod, settings: AppSettings) async throws -> String {
        guard isInstalled else { throw OllamaError.notInstalled }
        switch method {
        case .app:
            if let url = appURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.addsToRecentItems = false
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                    return "Opened Ollama.app"
                } catch {
                    throw OllamaError.startFailed(error.localizedDescription)
                }
            }
            fallthrough // no app bundle; use the CLI
        case .serve:
            return try startServe(settings: settings)
        }
    }

    private func startServe(settings: AppSettings) throws -> String {
        guard let cli = cliURL else { throw OllamaError.startFailed("The ollama command-line binary was not found.") }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        if let url = URL(string: settings.ollamaBaseURL), let host = url.host {
            env["OLLAMA_HOST"] = "\(host):\(url.port ?? 11434)"
        }
        // Documented server settings that materially affect memory use.
        env["OLLAMA_NUM_PARALLEL"] = String(max(1, settings.numParallel))
        env["OLLAMA_MAX_LOADED_MODELS"] = String(max(1, settings.maxLoadedModels))
        env["OLLAMA_FLASH_ATTENTION"] = settings.flashAttention ? "1" : "0"
        if settings.flashAttention { env["OLLAMA_KV_CACHE_TYPE"] = settings.kvCacheType.rawValue }
        if settings.contextLength > 0 { env["OLLAMA_CONTEXT_LENGTH"] = String(settings.contextLength) }
        process.environment = env

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
        } catch {
            throw OllamaError.startFailed(error.localizedDescription)
        }
        serveProcess = process
        return "Started ollama serve (pid \(process.processIdentifier))"
    }

    /// Stops only what can be stopped safely: our own `ollama serve` child, or Ollama.app via a normal quit.
    /// A server started some other way (e.g. `brew services`) is left alone and reported.
    func stop() async -> String {
        if let process = serveProcess, process.isRunning {
            process.terminate() // SIGTERM — Ollama shuts down cleanly
            for _ in 0..<40 where process.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
            serveProcess = nil
            return process.isRunning ? "ollama serve did not exit" : "Stopped ollama serve"
        }
        if let app = runningApp {
            app.terminate()
            for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(250)) }
            return app.isTerminated ? "Quit Ollama.app" : "Ollama.app did not quit"
        }
        return "Ollama was not started by an app Local AI Mode can quit (e.g. a launchd service); left running"
    }
}

/// Observable model/runtime state for the UI, backed by `OllamaClient`.
@MainActor
final class OllamaService: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var version: String?
    @Published private(set) var installedModels: [OllamaModel] = []
    @Published private(set) var runningModels: [OllamaRunningModel] = []
    @Published var modelStatus: ModelLoadStatus = .idle
    @Published private(set) var lastError: String?
    /// Sum of physical footprints of all `ollama` processes (server + runners), measured via libproc.
    @Published private(set) var measuredFootprintBytes: UInt64?
    @Published private(set) var estimates: [String: (total: Int64, kvCache: Int64?)] = [:]
    @Published private(set) var progressMessage: String?

    let launcher = OllamaLauncher()
    private var baseURLString: String = "http://localhost:11434"
    private var client: OllamaClient

    init(baseURL: String = "http://localhost:11434") {
        baseURLString = baseURL
        client = OllamaClient(baseURL: URL(string: baseURL) ?? URL(string: "http://localhost:11434")!)
    }

    func configure(baseURL: String) {
        guard baseURL != baseURLString, let url = URL(string: baseURL) else { return }
        baseURLString = baseURL
        client = OllamaClient(baseURL: url)
    }

    var totalReportedBytes: Int64 { runningModels.reduce(0) { $0 + $1.size } }

    // MARK: Refresh

    /// Lightweight status poll: version + loaded models. Installed models are refreshed less often.
    func refresh(includeInstalled: Bool = false, measureFootprint: Bool = false) async {
        isInstalled = launcher.isInstalled
        do {
            version = try await client.version()
            isReachable = true
            runningModels = try await client.runningModels()
            if includeInstalled || installedModels.isEmpty {
                installedModels = try await client.installedModels().sorted { $0.name < $1.name }
            }
            if lastError?.hasPrefix("Ollama's API") == true { lastError = nil }
        } catch {
            isReachable = false
            version = nil
            runningModels = []
        }
        if measureFootprint {
            let total = await Task.detached(priority: .utility) { () -> UInt64? in
                let procs = ProcessInspector.ollamaProcesses()
                guard !procs.isEmpty else { return nil }
                return procs.reduce(UInt64(0)) { $0 &+ (ProcessInspector.physicalFootprint(of: $1.pid) ?? 0) }
            }.value
            measuredFootprintBytes = total
        }
    }

    func estimate(for model: OllamaModel, contextLength: Int, kvType: KVCacheType) async {
        let info = try? await client.show(model: model.name)
        let bytesPerElement: Double = kvType == .q8_0 ? 1 : (kvType == .q4_0 ? 0.5 : 2)
        estimates[model.name] = ModelMemoryEstimator.estimate(fileSize: model.size, modelInfo: info?.model_info,
                                                              contextLength: contextLength, kvBytesPerElement: bytesPerElement)
    }

    // MARK: Lifecycle

    /// Makes sure the API is reachable, starting Ollama if needed. Returns true if Local AI Mode started it.
    func ensureRunning(settings: AppSettings) async throws -> Bool {
        if (try? await client.version()) != nil {
            isReachable = true
            return false
        }
        guard launcher.isInstalled else {
            isInstalled = false
            throw OllamaError.notInstalled
        }
        progressMessage = "Starting Ollama…"
        defer { progressMessage = nil }
        _ = try await launcher.start(method: settings.launchMethod, settings: settings)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if (try? await client.version()) != nil {
                await refresh(includeInstalled: true)
                return true
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw OllamaError.timeout("waiting for Ollama to start (30 s)")
    }

    /// Restarts Ollama under `ollama serve` so server settings (parallelism, KV cache type…) take effect.
    func restartWithServerSettings(_ settings: AppSettings) async throws {
        progressMessage = "Restarting Ollama with server settings…"
        defer { progressMessage = nil }
        _ = await unloadAll(timeout: settings.unloadTimeout)
        _ = await launcher.stop()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, (try? await client.version()) != nil {
            try await Task.sleep(for: .milliseconds(500))
        }
        if (try? await client.version()) != nil {
            throw OllamaError.startFailed("Another Ollama server is still listening (possibly a launchd service), so server settings could not be applied.")
        }
        var s = settings
        s.launchMethod = .serve
        _ = try await launcher.start(method: .serve, settings: s)
        let up = Date().addingTimeInterval(30)
        while Date() < up {
            if (try? await client.version()) != nil { await refresh(includeInstalled: true); return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw OllamaError.timeout("waiting for ollama serve to start")
    }

    /// Loads a model and verifies through `/api/ps` that it is actually resident.
    @discardableResult
    func loadModel(_ name: String, settings: AppSettings) async throws -> OllamaRunningModel {
        lastError = nil
        modelStatus = .loading(model: name, since: Date())
        do {
            if !installedModels.isEmpty, !installedModels.contains(where: { $0.name == name || $0.model == name }) {
                throw OllamaError.modelNotFound(name)
            }
            try await client.load(model: name, keepAlive: settings.keepAliveAPIValue,
                                  contextLength: settings.contextLength > 0 ? settings.contextLength : nil,
                                  timeout: settings.modelLoadTimeout)
            // Verify — a 200 from /api/generate alone is not proof the model stayed resident.
            var verified: OllamaRunningModel?
            for _ in 0..<10 {
                runningModels = try await client.runningModels()
                verified = runningModels.first { $0.name == name || $0.model == name }
                if verified != nil { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let model = verified else {
                throw OllamaError.verificationFailed("\(name) was not listed by /api/ps after loading")
            }
            modelStatus = .loaded(model: name)
            return model
        } catch is CancellationError {
            modelStatus = .idle
            throw CancellationError()
        } catch {
            let message = error.localizedDescription
            modelStatus = .failed(model: name, message: message)
            lastError = message
            throw error
        }
    }

    /// Requests `keep_alive: 0` for every loaded model. Ollama finishes in-flight generations before unloading,
    /// so active requests complete instead of being cut off. Returns the models still resident after `timeout`.
    func unloadAll(timeout: TimeInterval) async -> [String] {
        guard let loaded = try? await client.runningModels(), !loaded.isEmpty else {
            runningModels = []
            modelStatus = .idle
            return []
        }
        for model in loaded {
            modelStatus = .unloading(model: model.name)
            progressMessage = "Unloading \(model.name)…"
            // Fire-and-forget per model: the request returns when the unload is scheduled.
            try? await client.unload(model: model.name)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = loaded.map(\.name)
        while Date() < deadline {
            guard let current = try? await client.runningModels() else { remaining = []; break } // server gone
            runningModels = current
            remaining = current.map(\.name).filter { remaining.contains($0) }
            if remaining.isEmpty { break }
            progressMessage = "Waiting for \(remaining.joined(separator: ", ")) to finish and unload…"
            try? await Task.sleep(for: .seconds(1))
        }
        progressMessage = nil
        modelStatus = .idle
        if !remaining.isEmpty {
            lastError = "Still loaded after \(Int(timeout)) s (likely busy with a request): \(remaining.joined(separator: ", "))"
        }
        return remaining
    }

    func clearError() { lastError = nil }
}
