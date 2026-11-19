import XCTest
@testable import Local_AI_Mode

/// Intercepts URLSession traffic so the client can be tested without a running Ollama.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            return data
        }
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class OllamaClientTests: XCTestCase {
    var client: OllamaClient!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = OllamaClient(baseURL: URL(string: "http://localhost:11434")!, session: URLSession(configuration: config))
        MockURLProtocol.handler = nil
        MockURLProtocol.lastRequestBody = nil
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    // MARK: Request construction

    func testLoadRequestBody() throws {
        let req = try client.makeLoadRequest(model: "llama3.2:3b", keepAlive: .forever, contextLength: 8192, timeout: 600)
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:11434/api/generate")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.timeoutInterval, 600)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try json(req.httpBody)
        XCTAssertEqual(body["model"] as? String, "llama3.2:3b")
        XCTAssertEqual(body["prompt"] as? String, "")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? Int, -1)
        XCTAssertEqual((body["options"] as? [String: Any])?["num_ctx"] as? Int, 8192)
    }

    func testLoadRequestOmitsOptionsForDefaultContext() throws {
        let req = try client.makeLoadRequest(model: "m", keepAlive: .duration(seconds: 1800), contextLength: nil, timeout: 60)
        let body = try json(req.httpBody)
        XCTAssertNil(body["options"])
        XCTAssertEqual(body["keep_alive"] as? Int, 1800)
    }

    func testUnloadRequestUsesKeepAliveZero() throws {
        let body = try json(client.makeUnloadRequest(model: "m", timeout: 30).httpBody)
        XCTAssertEqual(body["keep_alive"] as? Int, 0)
        XCTAssertEqual(body["model"] as? String, "m")
    }

    func testKeepAliveLabels() {
        XCTAssertEqual(OllamaKeepAlive.forever.apiValue, -1)
        XCTAssertEqual(OllamaKeepAlive.unloadNow.apiValue, 0)
        XCTAssertEqual(OllamaKeepAlive.duration(seconds: 3600).label, "1 h")
    }

    // MARK: Responses

    func testDecodesRunningModels() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/ps")
            return (200, Data(#"{"models":[{"name":"gemma:2b","model":"gemma:2b","size":3000000000,"size_vram":1500000000,"expires_at":"2318-01-01T00:00:00.123456-08:00","context_length":8192}]}"#.utf8))
        }
        let models = try await client.runningModels()
        XCTAssertEqual(models.first?.name, "gemma:2b")
        XCTAssertEqual(models.first?.gpuFraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(models.first?.context_length, 8192)
        XCTAssertTrue(models.first?.neverExpires ?? false)
    }

    func testDecodesInstalledModels() async throws {
        MockURLProtocol.handler = { _ in
            (200, Data(#"{"models":[{"name":"qwen3:8b","size":5200000000,"details":{"family":"qwen3","parameter_size":"8.2B","quantization_level":"Q4_K_M"}}]}"#.utf8))
        }
        let models = try await client.installedModels()
        XCTAssertEqual(models.first?.details?.parameter_size, "8.2B")
    }

    func testLoadSendsBodyAndSucceeds() async throws {
        MockURLProtocol.handler = { _ in (200, Data(#"{"model":"m","done":true,"done_reason":"load"}"#.utf8)) }
        try await client.load(model: "m", keepAlive: .forever, contextLength: 4096, timeout: 30)
        let body = try json(MockURLProtocol.lastRequestBody)
        XCTAssertEqual(body["model"] as? String, "m")
    }

    // MARK: Errors

    func testModelNotFoundMapsTo404() async {
        MockURLProtocol.handler = { _ in (404, Data(#"{"error":"model 'nope' not found"}"#.utf8)) }
        do {
            try await client.load(model: "nope", keepAlive: .forever, contextLength: nil, timeout: 30)
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? OllamaError, .modelNotFound("nope"))
        }
    }

    func testInsufficientMemoryIsRecognised() async {
        MockURLProtocol.handler = { _ in
            (500, Data(#"{"error":"model requires more system memory (40.0 GiB) than is available (21.3 GiB)"}"#.utf8))
        }
        do {
            try await client.load(model: "big", keepAlive: .forever, contextLength: nil, timeout: 30)
            XCTFail("Expected error")
        } catch let OllamaError.insufficientMemory(message) {
            XCTAssertTrue(message.contains("40.0 GiB"))
        } catch {
            XCTFail("Wrong error \(error)")
        }
    }

    func testErrorFieldInSuccessfulResponseIsThrown() async {
        MockURLProtocol.handler = { _ in (200, Data(#"{"error":"llama runner process has terminated"}"#.utf8)) }
        do {
            try await client.load(model: "m", keepAlive: .forever, contextLength: nil, timeout: 30)
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? OllamaError, .http(status: 500, message: "llama runner process has terminated"))
        }
    }

    func testUnreachableServer() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await client.version()
            XCTFail("Expected error")
        } catch {
            guard case .unreachable = error as? OllamaError else { return XCTFail("Wrong error \(error)") }
        }
    }

    func testMalformedJSON() async {
        MockURLProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        do {
            _ = try await client.runningModels()
            XCTFail("Expected error")
        } catch {
            guard case .decoding = error as? OllamaError else { return XCTFail("Wrong error \(error)") }
        }
    }

    func testPlainTextErrorBody() {
        let e = OllamaError.from(status: 502, body: Data("Bad Gateway".utf8), model: nil)
        XCTAssertEqual(e, .http(status: 502, message: "Bad Gateway"))
    }

    // MARK: Estimate

    func testMemoryEstimateIncludesKVCache() {
        let info: [String: JSONValue] = [
            "general.architecture": .string("llama"),
            "llama.block_count": .number(32),
            "llama.embedding_length": .number(4096),
            "llama.attention.head_count": .number(32),
            "llama.attention.head_count_kv": .number(8),
        ]
        let est = ModelMemoryEstimator.estimate(fileSize: 4_000_000_000, modelInfo: info, contextLength: 8192)
        // 2 * 32 layers * 8192 ctx * 8 kv heads * 128 head dim * 2 bytes = 1 GiB
        XCTAssertEqual(est.kvCache, 1_073_741_824)
        XCTAssertEqual(est.total, 4_000_000_000 + 1_073_741_824)
        XCTAssertNil(ModelMemoryEstimator.estimate(fileSize: 10, modelInfo: nil, contextLength: 0).kvCache)
    }
}
