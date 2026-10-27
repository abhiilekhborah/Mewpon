import XCTest
@testable import MewponCore
@testable import MewponDesktop

final class FirstResponseTests: XCTestCase {
    func testOrdinaryFirstMessagesDoNotSendDesktopToolSchemas() {
        for prompt in ["Hi", "Hello!", "Hey Mewpon", "What is a binary tree?", "Who was Ada Lovelace?", "Tell me about recursion", "Translate hello to French", "Can you explain closures?"] {
            XCTAssertFalse(ToolContextPolicy.needsTools(prompt), prompt)
        }
        for prompt in ["Can you open Safari please?", "Find the most recent PDF", "Check my memory usage", "Show the selected text", "Switch to Finder", "What is my battery level?", "Where is my report?", "Summarize this", "What is in this folder?"] {
            XCTAssertTrue(ToolContextPolicy.needsTools(prompt), prompt)
        }
    }

    func testOptInFirstResponseMeasurement() async throws {
        guard let destination = ProcessInfo.processInfo.environment["MEWPON_FIRST_RESPONSE_OUTPUT"] else { throw XCTSkip("Explicit first-response measurement only") }
        var config = ModelConfiguration()
        config.model = "qwen3:4b-instruct"; config.maximumTokens = 64
        let service = OllamaService()
        try await service.ensureModel(config.model)
        if ProcessInfo.processInfo.environment["MEWPON_PRIME_FIRST_RESPONSE"] == "1" {
            try await service.preload(configuration: config)
            try await service.primeChat(configuration: config)
        }
        let router = ToolRouter(tools: [OpenApplicationTool(), PythonProjectTool(), OpenProjectTool(), RememberFileAliasTool(), FileSearchTool(), OpenFileTool(), FinderActionTool(), ReadDocumentTool(), ScreenTextTool(), ContextTool(), ApplicationControlTool(), VolumeTool(), WiFiStatusTool(), SystemSettingsTool(), SystemInfoTool(), DateTimeTool(), CalculatorTool()])
        var records: [[String: Any]] = []
        for (index, prompt) in ["Hi", "What is a binary tree?"].enumerated() {
            let start = ContinuousClock.now
            let definitions = ToolContextPolicy.needsTools(prompt) ? router.definitions : []
            let reply = try await service.chat(messages: [.init(role: "system", content: AgentController.systemPrompt), .init(role: "user", content: prompt)], tools: definitions, configuration: config, onText: { _ in })
            records.append(["sample": index, "prompt": prompt, "tools": definitions.count, "first_token_ms": (reply.firstTokenSeconds ?? -1) * 1000, "full_ms": elapsedMilliseconds(since: start), "load_ms": reply.inferenceMetrics?.loadMilliseconds ?? -1, "prompt_tokens": reply.inferenceMetrics?.promptTokens ?? -1, "generated_tokens": reply.inferenceMetrics?.generatedTokens ?? -1])
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: destination))
    }
}
