import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public func json() -> String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "null" }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public struct Function: Codable, Equatable, Sendable {
        public var name: String
        public var arguments: [String: JSONValue]
        public init(name: String, arguments: [String: JSONValue]) { self.name = name; self.arguments = arguments }
        enum CodingKeys: String, CodingKey { case name, arguments }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            if let object = try? c.decode([String: JSONValue].self, forKey: .arguments) { arguments = object }
            else {
                let string = try c.decode(String.self, forKey: .arguments)
                arguments = try JSONDecoder().decode([String: JSONValue].self, from: Data(string.utf8))
            }
        }
    }
    public var function: Function
    public init(name: String, arguments: [String: JSONValue] = [:]) { function = Function(name: name, arguments: arguments) }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String
    public var tool_calls: [ToolCall]?
    public var tool_name: String?
    // Local telemetry; never sent back to Ollama or persisted in chat content.
    public var firstTokenSeconds: Double? = nil
    public struct InferenceMetrics:Sendable,Equatable {
        public let loadMilliseconds:Double;public let promptTokens:Int;public let generatedTokens:Int;public let generationMilliseconds:Double
        public var tokensPerSecond:Double{generationMilliseconds>0 ? Double(generatedTokens)*1000/generationMilliseconds:0}
        public init(loadMilliseconds:Double,promptTokens:Int,generatedTokens:Int,generationMilliseconds:Double){self.loadMilliseconds=loadMilliseconds;self.promptTokens=promptTokens;self.generatedTokens=generatedTokens;self.generationMilliseconds=generationMilliseconds}
    }
    public var inferenceMetrics:InferenceMetrics? = nil
    enum CodingKeys: String, CodingKey { case role, content, tool_calls, tool_name }
    public init(role: String, content: String, toolCalls: [ToolCall]? = nil, toolName: String? = nil) {
        self.role = role; self.content = content; self.tool_calls = toolCalls; self.tool_name = toolName
    }
}

public struct ModelConfiguration: Codable, Equatable, Sendable {
    public var model = "qwen3:8b"
    public var temperature = 0.4
    public var contextWindow = 4096
    public var maximumTokens = 768
    public var timeout: Double = 120
    public var adaptiveAvatar = false
    public var keepAliveSeconds = 300
    public enum Thinking:String,Codable,CaseIterable,Sendable {case automatic,disabled,enabled}
    public var thinking:Thinking = .automatic
    public init() {}
    enum CodingKeys:String,CodingKey {case model,temperature,contextWindow,maximumTokens,timeout,keepAliveSeconds,thinking,adaptiveAvatar}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        model=try c.decodeIfPresent(String.self,forKey:.model) ?? "qwen3:8b"
        temperature=try c.decodeIfPresent(Double.self,forKey:.temperature) ?? 0.4
        contextWindow=try c.decodeIfPresent(Int.self,forKey:.contextWindow) ?? 4096
        maximumTokens=try c.decodeIfPresent(Int.self,forKey:.maximumTokens) ?? 768
        timeout=try c.decodeIfPresent(Double.self,forKey:.timeout) ?? 120
        adaptiveAvatar=try c.decodeIfPresent(Bool.self,forKey:.adaptiveAvatar) ?? false
        keepAliveSeconds=try c.decodeIfPresent(Int.self,forKey:.keepAliveSeconds) ?? 300
        thinking=try c.decodeIfPresent(Thinking.self,forKey:.thinking) ?? .automatic
    }
    public func validated() throws -> Self {
        guard !model.isEmpty, model.count <= 120, model.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.:/-]*$"#, options: .regularExpression) != nil,
              temperature.isFinite, (0...2).contains(temperature), (2048...8192).contains(contextWindow),
              (64...2048).contains(maximumTokens), timeout.isFinite, (5...300).contains(timeout), (0...900).contains(keepAliveSeconds) else {
            throw MewponError.invalid("Invalid model settings. Context: 2048–8192; response tokens: 64–2048; timeout: 5–300 seconds.")
        }
        return self
    }
}

public enum MewponError: LocalizedError, Equatable {
    case invalid(String), unavailable(String), server(String), timeout, incomplete
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .server(let s): return s
        case .timeout: return "The local model timed out. Retry, reduce context, or choose a smaller model."
        case .incomplete: return "Ollama closed the response before completion. Please retry."
        }
    }
}

public struct ToolResult: Codable, Equatable, Sendable {
    public var success: Bool
    public var summary: String
    public var items: [ResultItem]
    public var partial: Bool? = nil
    public init(_ success: Bool, _ summary: String, items: [ResultItem] = []) {
        self.success = success; self.summary = summary; self.items = items
    }
    public var json: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "{}" }
}
public struct ResultItem: Codable, Equatable, Identifiable, Sendable {
    public var modifiedAt: Date? = nil
    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: String
    public init(name: String, path: String, kind: String) { self.name = name; self.path = path; self.kind = kind }
}
