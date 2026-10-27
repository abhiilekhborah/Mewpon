import Foundation

public struct OllamaChunk: Decodable, Sendable {
    public struct Message: Decodable, Sendable {
        public let content: String?
        public let tool_calls: [ToolCall]?
    }
    public let message: Message?
    public let done: Bool?
    public let error: String?
    public let total_duration:UInt64?
    public let load_duration:UInt64?
    public let prompt_eval_count:Int?
    public let prompt_eval_duration:UInt64?
    public let eval_count:Int?
    public let eval_duration:UInt64?
}

public struct OllamaModel: Decodable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let size: Int64?
    public let capabilities: [String]?
}

private actor ModelState {
    static let shared=ModelState()
    var selected: String?
    var capabilities: [String: [String]] = [:]
    func previous() -> String? { selected }
    func select(_ name: String, capabilities: [String]?) {
        selected = name
        if self.capabilities.count>=16,self.capabilities[name]==nil{self.capabilities.removeAll(keepingCapacity:true)}
        self.capabilities[name] = capabilities
    }
    func supportsTools(_ name: String) -> Bool { capabilities[name]?.contains("tools") ?? true }
    func supportsThinking(_ name:String)->Bool{capabilities[name]?.contains("thinking") ?? name.lowercased().hasPrefix("qwen3:")}

}

public protocol LocalModelService: Sendable {
    func chat(messages: [ChatMessage], tools: [ToolDefinition], configuration: ModelConfiguration,
              onText: @escaping @Sendable (String) async -> Void) async throws -> ChatMessage
}

public final class OllamaService: LocalModelService, @unchecked Sendable {
    // Endpoint deliberately fixed to loopback; settings cannot redirect chat content to a remote host.
    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession
    private let modelState:ModelState
    private let modelCache=BoundedCache<String,[OllamaModel]>(capacity:1,ttl:.seconds(30))

    public init(session: URLSession? = nil) {
        modelState=session==nil ? .shared:ModelState()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.connectionProxyDictionary = [:]
        self.session = session ?? URLSession(configuration: config, delegate: LocalSessionDelegate(), delegateQueue: nil)
    }
    private func request(_ path: String, body: Data? = nil, timeout: Double = 10) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.timeoutInterval = timeout
        if let body { r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    public func models(forceRefresh:Bool=false) async throws -> [OllamaModel] {
        if !forceRefresh,let cached=await modelCache.value(for:"installed"){return cached}
        do {
            let (data, response) = try await session.data(for: request("api/tags"))
            try Self.validate(response, body: data)
            struct Models: Decodable { let models: [OllamaModel] }
            let values=try JSONDecoder().decode(Models.self, from: data).models
            await modelCache.insert(values,for:"installed");return values
        } catch { throw Self.friendly(error) }
    }
    public func ensureModel(_ name: String) async throws {
        let installed = try await models()
        guard let model = installed.first(where: { $0.name == name || $0.name == name + ":latest" }) else {
            throw MewponError.unavailable("Model \(name) is not installed. In Terminal run: ollama pull \(name). Downloads happen only when you choose to install.")
        }
        if let previous = await modelState.previous(), previous != name {
            // Only unload the previous model selected by this app, never every
            // model used by another local client. No new model is loaded here.
            struct Unload: Encodable { let model: String; let keep_alive = 0; let stream = false }
            let (data, response) = try await session.data(for: request("api/generate", body: JSONEncoder().encode(Unload(model: previous)), timeout: 20))
            try Self.validate(response, body: data)
        }
        await modelState.select(name, capabilities: model.capabilities)
    }
    /// An empty prompt loads installed weights without generating a response.
    public func preload(configuration: ModelConfiguration) async throws {
        let config = try configuration.validated()
        guard config.keepAliveSeconds > 0 else { return }
        try await ensureModel(config.model)
        let installed = try await models()
        guard installed.contains(where: { $0.name == config.model || $0.name == config.model + ":latest" }) else { throw MewponError.unavailable("Selected model is not installed.") }
        struct Body: Encodable { let model: String; let prompt = ""; let stream = false; let keep_alive: String; let options:[String:Int] }
        let start = ContinuousClock.now
        let (data, response) = try await session.data(for: request("api/generate", body: JSONEncoder().encode(Body(model: config.model, keep_alive: "\(config.keepAliveSeconds)s", options:["num_ctx":config.contextWindow])), timeout: min(60, config.timeout)))
        try Self.validate(response, body: data)
        await PerformanceProfiler.shared.record("startup.model_preload", since: start)
    }
    /// Prime only the shared chat prefix, never history, tools, or a user's request.
    /// Empty-prompt weight loading alone does not populate Ollama's prompt cache.
    public func primeChat(configuration: ModelConfiguration) async throws {
        let config = try configuration.validated()
        guard config.keepAliveSeconds > 0 else { return }
        try await ensureModel(config.model)
        let installed = try await models()
        guard let model = installed.first(where: { $0.name == config.model || $0.name == config.model + ":latest" }) else {
            throw MewponError.unavailable("Selected model is not installed.")
        }
        struct Body: Encodable {
            let model: String
            let messages = [ChatMessage(role: "system", content: AgentController.systemPrompt)]
            let stream = false
            let think: Bool?
            let keep_alive: String
            let options: [String: Int]
        }
        let body = Body(model: config.model, think: model.capabilities?.contains("thinking") == true ? false : nil,
                        keep_alive: "\(config.keepAliveSeconds)s", options: ["num_ctx": config.contextWindow, "num_predict": 1])
        let start = ContinuousClock.now
        let (data, response) = try await session.data(for: request("api/chat", body: JSONEncoder().encode(body), timeout: min(60, config.timeout)))
        try Self.validate(response, body: data)
        struct Reply: Decodable { let done: Bool?; let error: String? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if let error = reply.error { throw MewponError.server(error) }
        guard reply.done == true else { throw MewponError.incomplete }
        await PerformanceProfiler.shared.record("startup.chat_prefix", since: start)
    }
    public func chat(messages: [ChatMessage], tools: [ToolDefinition], configuration: ModelConfiguration,
                     onText: @escaping @Sendable (String) async -> Void) async throws -> ChatMessage {
        try await chatStructured(messages:messages,tools:tools,configuration:configuration,format:nil,onText:onText)
    }
    public func chatStructured(messages:[ChatMessage],tools:[ToolDefinition]=[],configuration:ModelConfiguration,format:JSONValue?,onText:@escaping @Sendable (String) async ->Void) async throws ->ChatMessage {
        let config = try configuration.validated()
        struct Body: Encodable {
            let model: String; let messages: [ChatMessage]; let tools: [ToolDefinition]?
            let stream = true; let think: Bool?; let keep_alive: String
            let options: Options
            let format:JSONValue?
            struct Options: Encodable { let temperature: Double; let num_ctx: Int; let num_predict: Int }
        }
        let supportsTools = await modelState.supportsTools(config.model)
        let thinkingSupported=await modelState.supportsThinking(config.model)
        let think:Bool?=thinkingSupported ? (config.thinking == .enabled):nil
        let body = Body(model: config.model, messages: messages, tools: tools.isEmpty || !supportsTools ? nil : tools,
                        think: think, keep_alive:"\(config.keepAliveSeconds)s",
                        options: .init(temperature: config.temperature, num_ctx: config.contextWindow, num_predict: config.maximumTokens),format:format)
        let req = request("api/chat", body: try JSONEncoder().encode(body), timeout: config.timeout)
        do {
            return try await withDeadline(seconds: config.timeout) { [self] in
                let started = ContinuousClock.now
                let (bytes, response) = try await session.bytes(for: req)
                try Self.validate(response)
                var content = "", calls: [ToolCall] = [], finished = false
                var firstToken: Double?
                let decoder=JSONDecoder()
                var responseBytes=0
                var metrics:ChatMessage.InferenceMetrics?

                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard !line.isEmpty else { continue }
                    guard line.utf8.count <= 1_048_576 else { throw MewponError.invalid("Oversized Ollama response.") }
                    responseBytes+=line.utf8.count
                    guard responseBytes<2_000_000 else{throw MewponError.invalid("Oversized Ollama stream.")}
                    let chunk = try decoder.decode(OllamaChunk.self, from: Data(line.utf8))
                    if let error = chunk.error { throw MewponError.server(error) }
                    if firstToken == nil, !(chunk.message?.content ?? "").isEmpty || !(chunk.message?.tool_calls ?? []).isEmpty {
                        let elapsed = started.duration(to: .now).components
                        firstToken = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                    }
                    if let text = chunk.message?.content, !text.isEmpty {
                        content += text
                        guard content.utf8.count < 131_072 else { throw MewponError.invalid("Response exceeded the safety limit.") }
                        await onText(text)
                    }
                    calls += chunk.message?.tool_calls ?? []
                    guard calls.count <= 6 else { throw MewponError.invalid("Too many tool calls in one response.") }
                    if chunk.done == true {
                        if let load=chunk.load_duration{await PerformanceProfiler.shared.record("llm.model_load",milliseconds:Double(load)/1e6)}
                        if let duration=chunk.eval_duration{await PerformanceProfiler.shared.record("llm.generation",milliseconds:Double(duration)/1e6)}
                        metrics = .init(loadMilliseconds:Double(chunk.load_duration ?? 0)/1e6,promptTokens:chunk.prompt_eval_count ?? 0,generatedTokens:chunk.eval_count ?? 0,generationMilliseconds:Double(chunk.eval_duration ?? 0)/1e6)
                        finished = true; break
                    }
                }
                guard finished else { throw MewponError.incomplete }
                var reply = ChatMessage(role: "assistant", content: content, toolCalls: calls.isEmpty ? nil : calls)
                reply.firstTokenSeconds = firstToken
                reply.inferenceMetrics=metrics
                if let firstToken{await PerformanceProfiler.shared.record("llm.first_token",milliseconds:firstToken*1000)}
                await PerformanceProfiler.shared.record("llm.full_response",since:started)
                return reply
            }
        } catch { await modelCache.removeAll();throw Self.friendly(error) }
    }
    static func validate(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let body, let value = try? JSONDecoder().decode([String: String].self, from: body), let message = value["error"] {
                throw MewponError.server(message)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MewponError.server("Ollama returned HTTP \(status). Check the selected model and Ollama version; retry after correcting them.")
        }
    }
    static func friendly(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if let e = error as? URLError {
            if e.code == .timedOut { return MewponError.timeout }
            return MewponError.unavailable("Cannot reach Ollama at 127.0.0.1:11434. Start the Ollama app or run ollama serve, then retry.")
        }
        return error
    }
}

private final class LocalSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public func withDeadline<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw MewponError.timeout }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
