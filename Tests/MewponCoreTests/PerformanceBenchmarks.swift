import AppKit
import XCTest
@testable import MewponCore
@testable import MewponDesktop

final class PerformanceBenchmarks: XCTestCase {
    func testOptInBaseline() async throws {
        guard let destination = ProcessInfo.processInfo.environment["MEWPON_BENCHMARK_OUTPUT"] else { throw XCTSkip("Explicit benchmark only") }
        var records: [[String: Any]] = []
        func measure(_ name: String, count: Int, operation: () async throws -> Void) async throws {
            print("Benchmarking \(name)");fflush(stdout)
            for index in 0..<count {
                let start = ContinuousClock.now
                try await operation()
                let c = start.duration(to: .now).components
                records.append(["operation":name,"sample":index,"milliseconds":Double(c.seconds)*1000+Double(c.attoseconds)/1e15])
            }
        }
        try await measure("application_lookup_safari", count: 30) { _ = try await OpenApplicationTool.resolve("Safari") }
        try await measure("application_lookup_finder", count: 30) { _ = try await OpenApplicationTool.resolve("Finder") }
        try await measure("application_lookup_absent", count: 5) { _ = try await OpenApplicationTool.resolve("MewponAbsentFixture") }
        try await measure("system_info", count: 30) { _ = try await SystemInfoTool().execute(arguments: [:]) }
        try await measure("date_time", count: 30) { _ = try await DateTimeTool().execute(arguments: [:]) }
        try await measure("calculator", count: 100) { _ = try await CalculatorTool().execute(arguments: ["expression":.string("145 * 23")]) }
        try await measure("spotlight_absent", count: 3) { _ = try await SpotlightSearch().search("MewponAbsentFixture864281") }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: destination))
    }
    func testOptInFastRouting() async throws {
        guard let destination=ProcessInfo.processInfo.environment["MEWPON_ROUTING_BENCHMARK_OUTPUT"] else{throw XCTSkip("Explicit benchmark only")}
        let router=FastIntentRouter();var records:[[String:Any]]=[]
        let prompts=["Open Safari.","Open Finder.","Show Downloads.","What's my battery?","What time is it?","Calculate 145 × 23.","Find my resume.","Find PDFs named report.","Explain recursion.","Write a simple C++ binary search function.","Find my report and open it."]
        for prompt in prompts{for index in 0..<100{let start=ContinuousClock.now;let result=await router.cachedRoute(prompt);records.append(["prompt":prompt,"sample":index,"milliseconds":elapsedMilliseconds(since:start),"decision":String(describing:result)])}}
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:destination))
    }
    func testOptInQualityComparison() async throws {
        guard let destination=ProcessInfo.processInfo.environment["MEWPON_QUALITY_BENCHMARK_OUTPUT"] else{throw XCTSkip("Explicit benchmark only")}
        let service=OllamaService();var records:[[String:Any]]=[]
        for model in ["qwen3:8b","qwen3:4b-instruct"] {
            try await service.ensureModel(model)
            for prompt in ["Explain recursion in two sentences.","Write a simple C++ binary search function. Return only a complete function.","Explain recursion in two sentences.","Explain recursion in two sentences."] {
                var config=ModelConfiguration();config.model=model;config.maximumTokens=384
                let start=ContinuousClock.now
                let reply=try await service.chat(messages:[.init(role:"system",content:AgentController.systemPrompt),.init(role:"user",content:prompt)],tools:[],configuration:config,onText:{_ in})
                records.append(["model":model,"prompt":prompt,"first_token_seconds":reply.firstTokenSeconds ?? -1,"milliseconds":elapsedMilliseconds(since:start),"response":reply.content,"load_ms":reply.inferenceMetrics?.loadMilliseconds ?? -1,"tokens_per_second":reply.inferenceMetrics?.tokensPerSecond ?? -1,"tokens":reply.inferenceMetrics?.generatedTokens ?? -1])
                try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:destination))
            }
        }
    }
    func testOptInContextQuality() async throws {
        guard let destination=ProcessInfo.processInfo.environment["MEWPON_CONTEXT_BENCHMARK_OUTPUT"] else{throw XCTSkip("Explicit benchmark only")}
        let service=OllamaService();var records:[[String:Any]]=[]
        for name in ["qwen3:8b","qwen3:4b-instruct"] {
            var config=ModelConfiguration();config.model=name;config.maximumTokens=384;try await service.ensureModel(name)
            let call=ToolCall(name:"search_files",arguments:["query":.string("resume")])
            let history:[ChatMessage]=[.init(role:"user",content:"Find my resume."),.init(role:"assistant",content:"",toolCalls:[call]),.init(role:"tool",content:ToolResult(false,"Permission denied. No action executed.").json,toolName:"search_files"),.init(role:"assistant",content:"Permission denied. No action executed."),.init(role:"user",content:"Write a simple C++ binary search function with a short explanation.")]
            let start=ContinuousClock.now
            let reply=try await AgentController(model:service,router:ToolRouter(tools:[])).respond(history:history,configuration:config,onText:{_ in},onEvent:{_ in},authorize:{_,_,_ in false},onResult:{_,_ in})
            records.append(["model":name,"milliseconds":elapsedMilliseconds(since:start),"response":reply.last?.content ?? ""])
            try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:destination))
        }
    }
    func testOptInModelBaseline() async throws {
        guard let destination=ProcessInfo.processInfo.environment["MEWPON_MODEL_BENCHMARK_OUTPUT"] else { throw XCTSkip("Explicit local inference benchmark only") }
        let service=OllamaService()
        var config=ModelConfiguration();config.maximumTokens=128
        if let model=ProcessInfo.processInfo.environment["MEWPON_BENCHMARK_MODEL"] {config.model=model}
        let tools=ToolRouter(tools:[OpenApplicationTool(),FileSearchTool(),OpenFileTool(),SystemInfoTool(),DateTimeTool(),CalculatorTool()])
        let prompts=["Open Safari.","Open Finder.","Show Downloads.","What's my battery?","What time is it?","Calculate 145 × 23.","Find my resume.","Find PDFs named report.","Explain recursion.","Write a simple C++ binary search function.","Find my report and open it."]
        var records:[[String:Any]]=[]
        for (index,prompt) in prompts.enumerated(){
            let start=ContinuousClock.now
            do {
                try await service.ensureModel(config.model)
                let reply=try await service.chat(messages:[ChatMessage(role:"system",content:AgentController.systemPrompt),ChatMessage(role:"user",content:prompt)],tools:ProcessInfo.processInfo.environment["MEWPON_BENCHMARK_OPTIMIZED"] == "1" && !ToolContextPolicy.needsTools(prompt) ? []:tools.definitions,configuration:config,onText:{_ in})
                let c=start.duration(to:.now).components
                records.append(["sample":index,"model":config.model,"prompt":prompt,"milliseconds":Double(c.seconds)*1000+Double(c.attoseconds)/1e15,"first_token_seconds":reply.firstTokenSeconds as Any? ?? NSNull(),"tool_names":reply.tool_calls?.map(\.function.name) ?? [],"response":reply.content,"load_ms":reply.inferenceMetrics?.loadMilliseconds ?? -1,"tokens_per_second":reply.inferenceMetrics?.tokensPerSecond ?? -1,"generated_tokens":reply.inferenceMetrics?.generatedTokens ?? -1,"prompt_tokens":reply.inferenceMetrics?.promptTokens ?? -1])
            } catch {records.append(["sample":index,"prompt":prompt,"error":error.localizedDescription])}
            try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:destination))
            print("Completed local model sample \(index+1)/\(prompts.count)")
        }
    }
}
