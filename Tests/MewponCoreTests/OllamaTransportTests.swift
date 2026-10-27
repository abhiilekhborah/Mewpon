import XCTest
@testable import MewponCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Plan { var body: String; var status = 200; var delay: Double = 0 }
    static let lock = NSLock()
    static var plan = Plan(body: "")
    static var requests: [URLRequest] = []
    private let stateLock = NSLock()
    private var stopped = false
    static func configure(_ value: Plan) { lock.lock(); defer { lock.unlock() }; plan = value; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            captured.httpBody = data
        }
        Self.lock.lock(); let plan = Self.plan; Self.requests.append(captured); Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + plan.delay) { [self] in
            stateLock.lock(); defer { stateLock.unlock() }; guard !stopped else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(plan.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

final class OllamaTransportTests: XCTestCase {
    private func service() -> OllamaService {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return OllamaService(session: URLSession(configuration: configuration))
    }
    func testPreloadUsesEmptyPromptAndRespectsKeepAliveOff() async throws {
        let api = service()
        StubProtocol.configure(.init(body: #"{"models":[{"name":"qwen3:8b","size":5000000000}]}"#))
        _ = try await api.models()
        StubProtocol.configure(.init(body: #"{"done":true}"#))
        var config = ModelConfiguration(); config.model = "qwen3:8b"
        try await api.preload(configuration: config)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/generate")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertEqual(body["prompt"] as? String, "")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? String, "300s")
        StubProtocol.configure(.init(body: "")); config.keepAliveSeconds = 0
        try await api.preload(configuration: config)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }
    func testChatPrimeUsesSharedPrefixOneTokenAndNoToolsOrHistory() async throws {
        let api = service()
        StubProtocol.configure(.init(body: #"{"models":[{"name":"qwen3:8b","capabilities":["thinking","tools"]}]}"#))
        _ = try await api.models()
        StubProtocol.configure(.init(body: #"{"done":true}"#))
        try await api.primeChat(configuration: ModelConfiguration())
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/chat")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, AgentController.systemPrompt)
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual((body["options"] as? [String: Int])?["num_predict"], 1)
        StubProtocol.configure(.init(body: ""))
        var off = ModelConfiguration(); off.keepAliveSeconds = 0
        try await api.primeChat(configuration: off)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }
    func testStreamingAndEndpoint() async throws {
        StubProtocol.configure(.init(body: "{\"message\":{\"content\":\"Hel\"},\"done\":false}\n{\"message\":{\"content\":\"lo\"},\"done\":false}\n{\"message\":{\"content\":\"\"},\"done\":true}\n"))
        let result = try await service().chat(messages: [ChatMessage(role: "user", content: "hi")], tools: [], configuration: ModelConfiguration(), onText: { _ in })
        XCTAssertEqual(result.content, "Hello")
        let request = StubProtocol.requests.first!
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(request.httpMethod, "POST")
    }
    func testListModelsAndMissingModel() async throws {
        StubProtocol.configure(.init(body: #"{"models":[{"name":"qwen3:8b","size":5000000000}]}"#))
        let models = try await service().models()
        XCTAssertEqual(models.first?.name, "qwen3:8b")
        XCTAssertEqual(StubProtocol.requests.first?.url?.path, "/api/tags")
        do { try await service().ensureModel("missing:8b"); XCTFail("Expected missing model") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ollama pull missing:8b")) }
    }
    func testIncompleteAndServerError() async {
        StubProtocol.configure(.init(body: "{\"message\":{\"content\":\"partial\"},\"done\":false}\n"))
        do { _ = try await service().chat(messages: [], tools: [], configuration: ModelConfiguration(), onText: { _ in }); XCTFail("Expected incomplete response") }
        catch { XCTAssertEqual(error as? MewponError, .incomplete) }
        StubProtocol.configure(.init(body: "error", status: 404))
        do { _ = try await service().chat(messages: [], tools: [], configuration: ModelConfiguration(), onText: { _ in }); XCTFail("Expected HTTP failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("404")) }
    }
    func testNetworkRequestCancellation() async throws {
        StubProtocol.configure(.init(body: "{\"done\":true}\n", delay: 3))
        let service = service()
        let task = Task { try await service.chat(messages: [], tools: [], configuration: ModelConfiguration(), onText: { _ in }) }
        try await Task.sleep(for: .milliseconds(40)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
    func testNetworkRequestTimeout() async throws {
        StubProtocol.configure(.init(body: "{\"done\":true}\n", delay: 20))
        var config = ModelConfiguration(); config.timeout = 5
        do { _ = try await service().chat(messages: [], tools: [], configuration: config, onText: { _ in }); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? MewponError, .timeout) }
    }
    func testSwitchingModelsUnloadsOnlyThePreviousSelection() async throws {
        StubProtocol.configure(.init(body: #"{"models":[{"name":"a:8b"},{"name":"b:4b"}]}"#))
        let service = service()
        try await service.ensureModel("a:8b")
        try await service.ensureModel("b:4b")
        XCTAssertEqual(StubProtocol.requests.map { $0.url!.path }, ["/api/tags", "/api/generate"])
    }
}
