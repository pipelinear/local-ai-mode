import Foundation

// MARK: - API types (https://github.com/ollama/ollama/blob/main/docs/api.md)

enum OllamaKeepAlive: Equatable, Sendable, Encodable {
    case forever
    case unloadNow
    case duration(seconds: Int)

    var apiValue: Int {
        switch self {
        case .forever: return -1
        case .unloadNow: return 0
        case .duration(let s): return max(1, s)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(apiValue)
    }

    var label: String {
        switch self {
        case .forever: return "Indefinitely"
        case .unloadNow: return "Unload immediately"
        case .duration(let s):
            if s % 3600 == 0 { return "\(s / 3600) h" }
            if s % 60 == 0 { return "\(s / 60) min" }
            return "\(s) s"
        }
    }
}

struct OllamaModelDetails: Codable, Hashable, Sendable {
    var format: String?
    var family: String?
    var parameter_size: String?
    var quantization_level: String?
}

struct OllamaModel: Codable, Hashable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var model: String?
    var size: Int64
    var digest: String?
    var modified_at: String?
    var details: OllamaModelDetails?
}

struct OllamaTagsResponse: Codable, Sendable {
    var models: [OllamaModel]
}

struct OllamaRunningModel: Codable, Hashable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var model: String?
    /// Total memory Ollama reports for this loaded model.
    var size: Int64
    /// Portion of `size` resident in GPU-addressable memory (on Apple Silicon, unified memory used by Metal).
    var size_vram: Int64?
    var expires_at: String?
    var context_length: Int?
    var details: OllamaModelDetails?

    var gpuFraction: Double {
        guard size > 0, let v = size_vram else { return 0 }
        return Double(v) / Double(size)
    }

    var expiresAt: Date? {
        guard let s = expires_at else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Ollama reports keep_alive = forever as an expiry far in the future.
    var neverExpires: Bool {
        guard let d = expiresAt else { return false }
        return d.timeIntervalSinceNow > 60 * 60 * 24 * 365 * 10
    }
}

struct OllamaPSResponse: Codable, Sendable {
    var models: [OllamaRunningModel]
}

struct OllamaVersionResponse: Codable, Sendable {
    var version: String
}

struct OllamaGenerateOptions: Encodable, Equatable, Sendable {
    var num_ctx: Int?
}

/// `POST /api/generate` with an empty prompt loads a model; with `keep_alive: 0` it unloads it.
struct OllamaGenerateRequest: Encodable, Equatable, Sendable {
    var model: String
    var prompt: String = ""
    var stream: Bool = false
    var keep_alive: OllamaKeepAlive
    var options: OllamaGenerateOptions?
}

struct OllamaGenerateResponse: Decodable, Sendable {
    var model: String?
    var done: Bool?
    var done_reason: String?
    var error: String?
}

struct OllamaShowRequest: Encodable, Sendable { var model: String }

/// Subset of `/api/show` used to estimate KV-cache memory.
struct OllamaShowResponse: Decodable, Sendable {
    var model_info: [String: JSONValue]?
    var details: OllamaModelDetails?
}

enum JSONValue: Decodable, Hashable, Sendable {
    case number(Double), string(String), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    var number: Double? {
        switch self {
        case .number(let n): return n
        case .array(let a): return a.compactMap(\.number).max()
        default: return nil
        }
    }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
}

// MARK: - Errors

enum OllamaError: LocalizedError, Equatable {
    case notInstalled
    case unreachable(String)
    case http(status: Int, message: String)
    case modelNotFound(String)
    case insufficientMemory(String)
    case decoding(String)
    case timeout(String)
    case verificationFailed(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Ollama is not installed. Download it from ollama.com, then try again."
        case .unreachable(let detail):
            return "Ollama's API is not reachable (\(detail))."
        case .http(let status, let message):
            return "Ollama returned HTTP \(status): \(message)"
        case .modelNotFound(let model):
            return "Model “\(model)” is not installed. Pull it with Ollama first."
        case .insufficientMemory(let message):
            return "Not enough memory to load the model: \(message)"
        case .decoding(let detail):
            return "Unexpected response from Ollama: \(detail)"
        case .timeout(let what):
            return "Timed out \(what)."
        case .verificationFailed(let detail):
            return "Model did not appear in Ollama's loaded models: \(detail)"
        case .startFailed(let detail):
            return "Could not start Ollama: \(detail)"
        }
    }

    /// Maps an HTTP error body to the most specific error.
    static func from(status: Int, body: Data, model: String?) -> OllamaError {
        let message = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
            ?? String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Unknown error"
        return classify(status: status, message: message, model: model)
    }

    static func classify(status: Int, message: String, model: String?) -> OllamaError {
        let lower = message.lowercased()
        if status == 404 || (lower.contains("not found") && lower.contains("model")) {
            return .modelNotFound(model ?? message)
        }
        if lower.contains("memory") || lower.contains("insufficient") || lower.contains("out of memory")
            || lower.contains("oom") {
            return .insufficientMemory(message)
        }
        return .http(status: status, message: message)
    }
}

// MARK: - Client

/// Thin, stateless HTTP client for Ollama's documented local API.
struct OllamaClient: Sendable {
    var baseURL: URL
    var session: URLSession

    init(baseURL: URL, session: URLSession = OllamaClient.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    // Request construction (exposed for tests)

    func makeRequest(path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func makeLoadRequest(model: String, keepAlive: OllamaKeepAlive, contextLength: Int?, timeout: TimeInterval) throws -> URLRequest {
        let options = contextLength.flatMap { $0 > 0 ? OllamaGenerateOptions(num_ctx: $0) : nil }
        let body = OllamaGenerateRequest(model: model, keep_alive: keepAlive, options: options)
        return makeRequest(path: "api/generate", method: "POST", body: try JSONEncoder().encode(body), timeout: timeout)
    }

    func makeUnloadRequest(model: String, timeout: TimeInterval) throws -> URLRequest {
        let body = OllamaGenerateRequest(model: model, keep_alive: .unloadNow)
        return makeRequest(path: "api/generate", method: "POST", body: try JSONEncoder().encode(body), timeout: timeout)
    }

    // Calls

    func version() async throws -> String {
        try await send(makeRequest(path: "api/version", timeout: 3), as: OllamaVersionResponse.self, model: nil).version
    }

    func installedModels() async throws -> [OllamaModel] {
        try await send(makeRequest(path: "api/tags"), as: OllamaTagsResponse.self, model: nil).models
    }

    func runningModels() async throws -> [OllamaRunningModel] {
        try await send(makeRequest(path: "api/ps", timeout: 5), as: OllamaPSResponse.self, model: nil).models
    }

    func show(model: String) async throws -> OllamaShowResponse {
        let body = try JSONEncoder().encode(OllamaShowRequest(model: model))
        return try await send(makeRequest(path: "api/show", method: "POST", body: body), as: OllamaShowResponse.self, model: model)
    }

    /// Returns once Ollama reports the load finished. The caller must still verify with `/api/ps`.
    func load(model: String, keepAlive: OllamaKeepAlive, contextLength: Int?, timeout: TimeInterval) async throws {
        let request = try makeLoadRequest(model: model, keepAlive: keepAlive, contextLength: contextLength, timeout: timeout)
        let response = try await send(request, as: OllamaGenerateResponse.self, model: model)
        if let error = response.error { throw OllamaError.classify(status: 500, message: error, model: model) }
    }

    func unload(model: String) async throws {
        _ = try await send(try makeUnloadRequest(model: model, timeout: 120), as: OllamaGenerateResponse.self, model: model)
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type, model: String?) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw OllamaError.timeout("waiting for \(request.url?.path ?? "Ollama")")
            case .cancelled: throw CancellationError()
            default: throw OllamaError.unreachable(error.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.decoding("Not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaError.from(status: http.statusCode, body: data, model: model)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OllamaError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Memory estimate

enum ModelMemoryEstimator {
    /// Estimate = weights (file size) + f16/q8/q4 KV cache for the requested context. This is an *estimate*;
    /// the authoritative figure is `size` from `/api/ps` once loaded.
    static func estimate(fileSize: Int64, modelInfo: [String: JSONValue]?, contextLength: Int, kvBytesPerElement: Double = 2) -> (total: Int64, kvCache: Int64?) {
        guard let info = modelInfo,
              let arch = info["general.architecture"]?.string,
              let layers = info["\(arch).block_count"]?.number,
              let embed = info["\(arch).embedding_length"]?.number,
              let heads = info["\(arch).attention.head_count"]?.number, heads > 0 else {
            return (fileSize, nil)
        }
        let kvHeads = info["\(arch).attention.head_count_kv"]?.number ?? heads
        let headDim = info["\(arch).attention.key_length"]?.number ?? (embed / heads)
        let ctx = Double(contextLength > 0 ? contextLength : Int(info["\(arch).context_length"]?.number ?? 4096))
        // Ollama defaults to a 4096 context unless configured; cap at the model's maximum.
        let effectiveCtx = contextLength > 0 ? ctx : min(ctx, 4096)
        let kv = 2 * layers * effectiveCtx * kvHeads * headDim * kvBytesPerElement
        return (fileSize + Int64(kv), Int64(kv))
    }
}
