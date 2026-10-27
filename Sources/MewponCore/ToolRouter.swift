import Foundation

public enum Capability: String, Codable, CaseIterable, Sendable {
    case network, launchApplication, searchFiles, openPath, inspectFile, systemControl, context, fileChanges, windowControl, appearance, routine, externalAutomation
    public var label: String {
        switch self {
        case .network:return "Use the requested online source or browser navigation"
        case .externalAutomation: return "Review the exact registered workflow before executing project code"
        case .fileChanges: return "Create, copy, move, or rename files in authorized folders"
        case .windowControl: return "Arrange or control application windows"
        case .appearance: return "Change the requested appearance"
        case .routine: return "Run an explicitly saved routine"
        case .inspectFile: return "Reveal a file or read its Quick Look preview"
        case .systemControl: return "Control an application or system setting"
        case .context: return "Read context for this task"
        case .launchApplication: return "Open an installed application"
        case .searchFiles: return "Search file names in your home folder"
        case .openPath: return "Open a document or folder"
        }
    }
}

public struct ToolDefinition: Encodable, Sendable {
    public let type = "function"
    public let function: Function
    public struct Function: Encodable, Sendable {
        public let name: String
        public let description: String
        public let parameters: JSONValue
    }
    public init(name: String, description: String, fields: [String: String] = [:]) {
        function = Function(name: name, description: description, parameters: .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "required": .array(fields.keys.sorted().map(JSONValue.string)),
            "properties": .object(fields.mapValues { .object(["type": .string("string"), "description": .string($0)]) })
        ]))
    }
}

public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let fields: [String: String]
    public let capability: Capability?
    public let timeout: Double
    public let multilineFields: Set<String>
    public init(_ name: String, _ description: String, fields: [String: String] = [:], capability: Capability? = nil, timeout: Double = 10, multilineFields: Set<String> = []) {
        self.name = name; self.description = description; self.fields = fields; self.capability = capability; self.timeout = timeout; self.multilineFields = multilineFields
    }
    public var definition: ToolDefinition { ToolDefinition(name: name, description: description, fields: fields) }
    public func validate(_ arguments: [String: JSONValue]) throws {
        guard Set(arguments.keys) == Set(fields.keys) else { throw MewponError.invalid("Invalid arguments for \(name). Required: \(fields.keys.sorted().joined(separator: ", ")).") }
        for (key, value) in arguments {
            guard let string = value.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  string.count <= 1024, !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !(multilineFields.contains(key) && $0.value == 10) }) else {
                throw MewponError.invalid("\(key) must be a nonempty string of at most 1024 characters, without control characters.")
            }
        }
    }
}

public protocol AssistantTool: Sendable {
    var spec: ToolSpec { get }
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult
}

public struct ToolRouter: Sendable {
    private let tools: [String: any AssistantTool]
    private let canExecute: @Sendable (String) async -> Bool
    public init(tools: [any AssistantTool], canExecute: @escaping @Sendable (String) async -> Bool = { _ in true }) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.spec.name, $0) }); self.canExecute = canExecute
    }
    public var definitions: [ToolDefinition] { tools.values.sorted { $0.spec.name < $1.spec.name }.map { $0.spec.definition } }
    public func execute(_ call: ToolCall,
                        authorize: @escaping @Sendable (Capability, String, [String: JSONValue]) async -> Bool) async -> ToolResult {
        guard await canExecute(call.function.name) else { return ToolResult(false, "Automation is disabled. No action executed.") }
        guard let tool = tools[call.function.name] else { return ToolResult(false, "Unknown tool: \(call.function.name). No action executed.") }
        do {
            try Task.checkCancellation()
            let validationStart=ContinuousClock.now
            try tool.spec.validate(call.function.arguments)
            await PerformanceProfiler.shared.record("tool.validation",since:validationStart)
            if let capability = tool.spec.capability {
                let approvalStart=ContinuousClock.now
                let approved=await authorize(capability, tool.spec.name, call.function.arguments)
                await PerformanceProfiler.shared.record("tool.authorization_wait",since:approvalStart)
                guard approved else {
                    return ToolResult(false, "Permission denied. No action executed.")
                }
            }
            try Task.checkCancellation()
            let start=ContinuousClock.now
            let result=try await withDeadline(seconds: tool.spec.timeout) { try await tool.execute(arguments: call.function.arguments) }
            await PerformanceProfiler.shared.record("tool."+tool.spec.name,since:start)
            return result
        } catch is CancellationError { return ToolResult(false, "Cancelled. No further action will be executed.") }
        catch MewponError.timeout {return ToolResult(false,"The action timed out while waiting for macOS. An action already accepted by the OS may still complete; no further action was started.")}
        catch { return ToolResult(false, error.localizedDescription) }
    }
}

public struct DateTimeTool: AssistantTool {
    public let spec = ToolSpec("date_time", "Return the device's actual local date, time, and timezone.")
    public init() {}
    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.timeStyle = .long
        return ToolResult(true, formatter.string(from: Date()) + " (" + TimeZone.current.identifier + ")")
    }
}

public struct CalculatorTool: AssistantTool {
    public let spec = ToolSpec("calculator", "Evaluate arithmetic using + - * / % ^ and parentheses. No code or functions.", fields: ["expression": "Arithmetic expression"])
    public init() {}
    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let expression = arguments["expression"]?.string else { throw MewponError.invalid("Missing expression.") }
        return ToolResult(true, String(try Calculator.evaluate(expression)))
    }
}

public enum ApplicationLookup {
    public static func matches(query: String, candidates: [ResultItem]) -> [ResultItem] {
        let aliases = ["vs code": "visual studio code", "vscode": "visual studio code"]
        let q = query.lowercased().replacingOccurrences(of: ".app", with: "")
        let normalized = aliases[q] ?? q
        let exact = candidates.filter { $0.name.lowercased().replacingOccurrences(of: ".app", with: "") == normalized }
        if !exact.isEmpty { return exact }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(normalized) }
    }
}

public enum FileSearchResults {
    public static func items(paths: [String], exists: (String) -> Bool) -> [ResultItem] {
        Array(Set(paths)).sorted().filter(exists).prefix(20).map {
            let url = URL(fileURLWithPath: $0)
            return ResultItem(name: url.lastPathComponent, path: url.path, kind: url.pathExtension.isEmpty ? "folder or file" : url.pathExtension)
        }
    }
}
