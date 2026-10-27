import XCTest
@testable import MewponCore

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
private struct SpyTool: AssistantTool {
    let counter: Counter
    let spec = ToolSpec("spy", "A test action", fields: ["name": "name"], capability: .launchApplication)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult { await counter.increment(); return ToolResult(true, "done") }
}
private actor ScriptedModel: LocalModelService {
    var replies: [ChatMessage]
    var received: [[ChatMessage]] = []
    init(_ replies: [ChatMessage]) { self.replies = replies }
    func chat(messages: [ChatMessage], tools: [ToolDefinition], configuration: ModelConfiguration, onText: @escaping @Sendable (String) async -> Void) async throws -> ChatMessage {
        received.append(messages)
        guard !replies.isEmpty else { throw MewponError.invalid("Test ran out of replies") }
        let reply = replies.removeFirst()
        if !reply.content.isEmpty { await onText(reply.content) }
        return reply
    }
}

final class CoreTests: XCTestCase {
    func testOllamaDecoding() throws {
        let chunk = try JSONDecoder().decode(OllamaChunk.self, from: Data(#"{"message":{"role":"assistant","content":"Hello","tool_calls":[{"function":{"name":"calculator","arguments":{"expression":"2+2"}}}]},"done":true}"#.utf8))
        XCTAssertEqual(chunk.message?.content, "Hello")
        XCTAssertEqual(chunk.message?.tool_calls?.first?.function.arguments["expression"], .string("2+2"))
        XCTAssertEqual(chunk.done, true)
        let error = try JSONDecoder().decode(OllamaChunk.self, from: Data(#"{"error":"missing model"}"#.utf8))
        XCTAssertEqual(error.error, "missing model")
    }
    func testToolCallStringArgumentsAndMalformedArguments() throws {
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(#"{"function":{"name":"calculator","arguments":"{\"expression\":\"3*4\"}"}}"#.utf8))
        XCTAssertEqual(call.function.arguments["expression"], .string("3*4"))
        XCTAssertThrowsError(try JSONDecoder().decode(ToolCall.self, from: Data(#"{"function":{"name":"x","arguments":"not JSON"}}"#.utf8)))
    }
    func testUnknownToolRejection() async {
        let router = ToolRouter(tools: [DateTimeTool()])
        let result = await router.execute(ToolCall(name: "shell", arguments: ["command": .string("rm -rf /")])) { _, _, _ in XCTFail("Must not authorize an unknown tool"); return true }
        XCTAssertFalse(result.success); XCTAssertTrue(result.summary.contains("Unknown tool"))
    }
    func testInvalidArgumentsNeverExecuteOrAskPermission() async {
        let counter = Counter(), tool = SpyTool(counter: Counter())
        let router = ToolRouter(tools: [tool])
        for arguments: [String: JSONValue] in [[:], ["name": .number(3)], ["name": .string("okay"), "extra": .string("bad")], ["name": .string("a\nb")], ["name": .string(String(repeating: "a", count: 1025))]] {
            let result = await router.execute(ToolCall(name: "spy", arguments: arguments)) { _, _, _ in await counter.increment(); return true }
            XCTAssertFalse(result.success)
        }
        let prompts = await counter.value, calls = await tool.counter.value
        XCTAssertEqual(prompts, 0); XCTAssertEqual(calls, 0)
    }
    func testPermissionDenial() async {
        let counter = Counter()
        let router = ToolRouter(tools: [SpyTool(counter: counter)])
        let result = await router.execute(ToolCall(name: "spy", arguments: ["name": .string("Safari")])) { capability, _, _ in
            XCTAssertEqual(capability, .launchApplication); return false
        }
        XCTAssertFalse(result.success)
        let calls = await counter.value
        XCTAssertEqual(calls, 0)
    }
    func testCalculator() throws {
        XCTAssertEqual(try Calculator.evaluate("2 + 3 * (4 - 1)"), 11)
        XCTAssertEqual(try Calculator.evaluate("-2^2"), -4)
        XCTAssertEqual(try Calculator.evaluate("2^3^2"), 512)
        XCTAssertEqual(try Calculator.evaluate("5 % 2 + .25"), 1.25)
        for text in ["1/0", "sqrt(2)", "1;open Safari", "2**3", "2+", "1..2", String(repeating: "(", count: 40) + "1" + String(repeating: ")", count: 40), "9^999"] { XCTAssertThrowsError(try Calculator.evaluate(text), text) }
    }
    func testApplicationLookupAndAmbiguity() {
        let candidates = [ResultItem(name: "Safari", path: "/Applications/Safari.app", kind: "application"), ResultItem(name: "Safari Technology Preview", path: "/Applications/Preview.app", kind: "application"), ResultItem(name: "Visual Studio Code", path: "/Applications/Code.app", kind: "application")]
        XCTAssertEqual(ApplicationLookup.matches(query: "safari", candidates: candidates).count, 1)
        XCTAssertEqual(ApplicationLookup.matches(query: "vs code", candidates: candidates).first?.name, "Visual Studio Code")
        XCTAssertEqual(ApplicationLookup.matches(query: "saf", candidates: candidates).count, 2)
        XCTAssertTrue(ApplicationLookup.matches(query: "Missing app", candidates: candidates).isEmpty)
    }
    func testFileSearchResults() {
        let items = FileSearchResults.items(paths: ["/tmp/report.pdf", "/tmp/gone.txt", "/tmp/report.pdf", "/tmp/a.txt"]) { $0 != "/tmp/gone.txt" }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.last?.kind, "pdf"); XCTAssertEqual(items.last?.name, "report.pdf")
    }
    func testTimeoutAndCancellation() async throws {
        do {
            let _: String = try await withDeadline(seconds: 0.02) { try await Task.sleep(for: .seconds(20)); return "bad" }
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? MewponError, .timeout) }
        let task = Task { try await withDeadline(seconds: 10) { try await Task.sleep(for: .seconds(20)); return "bad" } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testConversationTrimmingKeepsToolSequences() {
        var conversation = Conversation()
        for i in 0..<40 {
            conversation.append(ChatMessage(role: "user", content: "Question \(i)"))
            conversation.append(ChatMessage(role: "assistant", content: "", toolCalls: [ToolCall(name: "date_time")]))
            conversation.append(ChatMessage(role: "tool", content: "actual date", toolName: "date_time"))
            conversation.append(ChatMessage(role: "assistant", content: "The date is…"))
        }
        XCTAssertLessThanOrEqual(conversation.messages.count, 80)
        XCTAssertEqual(conversation.messages.first?.role, "user")
        conversation.clear(); XCTAssertTrue(conversation.messages.isEmpty)
    }
    func testStoreAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory)
        var conversation = Conversation(); conversation.append(ChatMessage(role: "user", content: "hello"))
        try await store.save(conversation)
        let loaded = try await store.load(); XCTAssertEqual(loaded, conversation)
        try await store.log(tool: "date_time", success: true)
        let log = try String(contentsOf: directory.appendingPathComponent("actions.log"))
        XCTAssertFalse(log.contains("hello")); XCTAssertTrue(log.contains("date_time success"))
        try await store.clear(); let cleared = try await store.load(); XCTAssertTrue(cleared.messages.isEmpty)
    }
    func testAvatarMappingsUseExistingCatalog() {
        for event in AssistantEvent.allCases {
            let mapping = AvatarMapping.mapping(for: event)
            XCTAssertTrue(AvatarMapping.expressions.contains(mapping.expression))
            if let activity = mapping.activity { XCTAssertTrue(AvatarMapping.activities.contains(activity)) }
        }
        XCTAssertEqual(AvatarMapping.mapping(for: .searching).activity, "searching")
        XCTAssertEqual(AvatarMapping.mapping(for: .responding).activity, "talking")
    }
    func testToolLoopUsesActualResult() async throws {
        let model = ScriptedModel([ChatMessage(role: "assistant", content: "", toolCalls: [ToolCall(name: "calculator", arguments: ["expression": .string("6*7")])]), ChatMessage(role: "assistant", content: "42")])
        let agent = AgentController(model: model, router: ToolRouter(tools: [CalculatorTool()]))
        let result = try await agent.respond(history: [ChatMessage(role: "user", content: "6*7")], configuration: ModelConfiguration(), onText: { _ in }, onEvent: { _ in }, authorize: { _, _, _ in XCTFail("Arithmetic needs no permission"); return false }, onResult: { _, result in XCTAssertEqual(result.summary, "42.0") })
        XCTAssertEqual(result.last?.content, "42")
        let received = await model.received
        XCTAssertEqual(received.last?.last?.role, "tool")
        XCTAssertTrue(received.last?.last?.content.contains("42.0") == true)
    }
    func testToolLoopIsBounded() async {
        let reply = ChatMessage(role: "assistant", content: "", toolCalls: [ToolCall(name: "date_time")])
        let model = ScriptedModel(Array(repeating: reply, count: 10))
        let agent = AgentController(model: model, router: ToolRouter(tools: [DateTimeTool()]))
        do { _ = try await agent.respond(history: [], configuration: ModelConfiguration(), onText: { _ in }, onEvent: { _ in }, authorize: { _, _, _ in true }, onResult: { _, _ in }); XCTFail("Expected iteration limit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("iteration limit")) }
        let count = await model.received.count; XCTAssertEqual(count, 4)
    }
    func testDeniedToolStopsModelAndLaterActions() async throws {
        let counter = Counter()
        let model = ScriptedModel([ChatMessage(role: "assistant", content: "", toolCalls: [ToolCall(name: "spy", arguments: ["name": .string("Safari")]), ToolCall(name: "spy", arguments: ["name": .string("Finder")])])])
        let agent = AgentController(model: model, router: ToolRouter(tools: [SpyTool(counter: counter)]))
        let result = try await agent.respond(history: [], configuration: ModelConfiguration(), onText: { _ in }, onEvent: { _ in }, authorize: { _, _, _ in false }, onResult: { _, _ in })
        XCTAssertEqual(result.last?.content, "Permission denied. No action executed.")
        XCTAssertEqual(result.filter { $0.role == "tool" }.count, 2)
        let executed = await counter.value, requests = await model.received.count
        XCTAssertEqual(executed, 0); XCTAssertEqual(requests, 1)
    }
    func testConfigurationValidation() throws {
        _ = try ModelConfiguration().validated()
        var config = ModelConfiguration(); config.contextWindow = 99999
        XCTAssertThrowsError(try config.validated())
        config = ModelConfiguration(); config.model = "x\nexecute"; XCTAssertThrowsError(try config.validated())
    }
}
