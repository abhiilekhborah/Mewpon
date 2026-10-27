import XCTest
@testable import MewponCore

private actor CountingModel:LocalModelService {
    var calls=0
    func chat(messages:[ChatMessage],tools:[ToolDefinition],configuration:ModelConfiguration,onText:@escaping @Sendable(String) async ->Void) async throws ->ChatMessage {calls+=1;await onText("Model answer");return ChatMessage(role:"assistant",content:"Model answer")}
}
private actor Executions {
    var names:[String]=[]
    func add(_ s:String){names.append(s)}
}
private struct FixtureTool:AssistantTool {
    let spec:ToolSpec;let result:ToolResult;let log:Executions
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult{await log.add(spec.name);return result}
}
private struct UnexpectedToolModel:LocalModelService {
    func chat(messages:[ChatMessage],tools:[ToolDefinition],configuration:ModelConfiguration,onText:@escaping @Sendable(String) async ->Void) async throws ->ChatMessage {
        ChatMessage(role:"assistant",content:"",toolCalls:[ToolCall(name:"open_application",arguments:["application":.string("Safari")])])
    }
}
final class HybridRoutingTests:XCTestCase {
    func testRecognizedCommandsAndSafeFallbacks(){
        let cases:[String:String] = ["Open Safari.":"open_application","Launch VS Code":"open_application","Show Downloads.":"open_path","What's my battery?":"system_info","What time is it?":"date_time","Calculate 145 × 23.":"calculator","Find my resume.":"search_files","Find PDFs named report.":"search_files","Where is my internship report?":"search_files","Find the Python file named main.":"search_files","Find PDFs from last week.":"search_files","Show my recent presentations.":"search_files","Opne Safari":"open_application"]
        for (text,name) in cases {guard case .deterministic(.tool(let call))=FastIntentRouter.classify(text) else{XCTFail(text);continue};XCTAssertEqual(call.function.name,name,text)}
        for text in ["Explain how Safari works","Don't open Safari","Do not open Safari","Can you tell me how to open Safari?","\"Open Safari\"","'open Safari'","Open Safari and Terminal","Open the file I was editing yesterday","if I say open Safari","open it when ready","Open Safari; delete files","What does open Safari mean?"] {XCTAssertEqual(FastIntentRouter.classify(text),.requiresLLM,text)}
        guard case .needsClarification=FastIntentRouter.classify("open it") else{return XCTFail("Ambiguous reference")}
        XCTAssertEqual(FastIntentRouter.classify("Find my report and open it."),.deterministic(.searchAndOpen(query:"report")))
    }
    func testRememberCVRequiresOnePriorCandidate() async throws {
        XCTAssertEqual(FastIntentRouter.classify("this is my cv"),.deterministic(.rememberFileAlias(alias:"resume cv curriculum vitae")))
        for count in [0,1,2] {
            let log=Executions(),model=CountingModel()
            let tool=FixtureTool(spec:.init("remember_file_alias","fixture",fields:["path":"file","alias":"association"],capability:.searchFiles),result:.init(true,"Remembered"),log:log)
            let found=ToolResult(true,"Found",items:(0..<count).map{.init(name:"\($0).pdf",path:"/fixture/\($0).pdf",kind:"pdf")})
            let history:[ChatMessage]=[.init(role:"user",content:"find cv"),.init(role:"tool",content:found.json,toolName:"search_files"),.init(role:"assistant",content:"Found"),.init(role:"user",content:"this is my cv")]
            _ = try await HybridAgentController(model:model,router:ToolRouter(tools:[tool])).respond(decision:FastIntentRouter.classify("this is my cv"),history:history,configuration:.init(),onText:{_ in},onEvent:{_ in},authorize:{_,_,_ in true},onResult:{_,_ in})
            let names=await log.names,calls=await model.calls
            XCTAssertEqual(names,count==1 ? ["remember_file_alias"]:[]);XCTAssertEqual(calls,0)
        }
    }
    func testOfflineFastPathAndPermissionDenial() async throws {
        let model=CountingModel(),log=Executions()
        let router=ToolRouter(tools:[FixtureTool(spec:.init("open_application","fixture",fields:["application":"name"],capability:.launchApplication),result:.init(true,"Opened"),log:log)])
        let agent=HybridAgentController(model:model,router:router)
        let messages=try await agent.respond(decision:FastIntentRouter.classify("Open Safari"),history:[],configuration:.init(),onText:{_ in},onEvent:{_ in},authorize:{_,_,_ in false},onResult:{_,_ in})
        let calls=await model.calls,names=await log.names
        XCTAssertEqual(calls,0);XCTAssertEqual(names,[]);XCTAssertTrue(messages.last!.content.contains("Permission denied"))
        _ = try await agent.respond(decision:.requiresLLM,history:[.init(role:"user",content:"Explain recursion")],configuration:.init(),onText:{_ in},onEvent:{_ in},authorize:{_,_,_ in false},onResult:{_,_ in})
        let modelCalls=await model.calls;XCTAssertEqual(modelCalls,1)
    }
    func testWorkflowIsSequentialAndRequiresBothApprovals() async throws {
        let model=CountingModel(),log=Executions(),approvals=Executions()
        let search=FixtureTool(spec:.init("search_files","fixture",fields:["query":"name"],capability:.searchFiles),result:.init(true,"Found",items:[.init(name:"report.pdf",path:"/fixture/report.pdf",kind:"pdf")]),log:log)
        let open=FixtureTool(spec:.init("open_path","fixture",fields:["path":"path"],capability:.openPath),result:.init(true,"Opened report.pdf"),log:log)
        let agent=HybridAgentController(model:model,router:ToolRouter(tools:[search,open]))
        _ = try await agent.respond(decision:.deterministic(.searchAndOpen(query:"report")),history:[],configuration:.init(),onText:{_ in},onEvent:{_ in},authorize:{_,name,_ in await approvals.add(name);return name=="search_files"},onResult:{_,_ in})
        let names=await log.names,asked=await approvals.names,calls=await model.calls
        XCTAssertEqual(names,["search_files"]);XCTAssertEqual(asked,["search_files","open_path"]);XCTAssertEqual(calls,0)
    }
    func testAmbiguousAndIncompleteSearchNeverOpens() async throws {
        for count in [0,1,2] {
            let log=Executions();var found=ToolResult(true,"Found",items:(0..<count).map{.init(name:"\($0).pdf",path:"/fixture/\($0).pdf",kind:"pdf")});found.partial=count==1
            let agent=HybridAgentController(model:CountingModel(),router:ToolRouter(tools:[FixtureTool(spec:.init("search_files","fixture",fields:["query":"name"],capability:.searchFiles),result:found,log:log)]))
            let result=try await agent.respond(decision:.deterministic(.searchAndOpen(query:"report")),history:[],configuration:.init(),onText:{_ in},onEvent:{_ in},authorize:{_,_,_ in true},onResult:{_,_ in})
            let names=await log.names;XCTAssertEqual(names,["search_files"]);XCTAssertTrue(result.last!.content.contains("Nothing was opened"))
        }
    }
    func testNegatedAndQuotedPromptsCannotExecuteUnsolicitedModelTools() async throws {
        for prompt in ["Don't open Safari","Can you tell me how to open Safari?","\"Open Safari\"","The instruction 'open Safari' is an example","‘Open Safari’"]{
            let log=Executions()
            let agent=HybridAgentController(model:UnexpectedToolModel(),router:ToolRouter(tools:[FixtureTool(spec:.init("open_application","fixture",fields:["application":"name"],capability:.launchApplication),result:.init(true,"Opened"),log:log)]))
            do{_ = try await agent.respond(decision:.requiresLLM,history:[.init(role:"user",content:prompt)],configuration:.init(),onText:{_ in},onEvent:{_ in},authorize:{_,_,_ in XCTFail("Must not request permission");return false},onResult:{_,_ in});XCTFail("Expected unsolicited tool rejection")}
            catch{XCTAssertTrue(error.localizedDescription.contains("blocked"))}
            let names=await log.names;XCTAssertTrue(names.isEmpty)
        }
    }
    func testContextExplanationRequiresApprovalAndCannotRunOtherTools() async throws {
        for allowed in [false, true] {
            let model = CountingModel(), log = Executions()
            let context = FixtureTool(spec: .init("read_context", "fixture", fields: ["kind": "source"], capability: .context), result: .init(true, "Selected text: a simple loop"), log: log)
            let agent = HybridAgentController(model: model, router: ToolRouter(tools: [context]))
            _ = try await agent.respond(decision: .deterministic(.explainContext(kind: "selectedText")), history: [.init(role: "user", content: "Explain selected text")], configuration: .init(), onText: { _ in }, onEvent: { _ in }, authorize: { _, _, _ in allowed }, onResult: { _, _ in })
            let calls = await model.calls, names = await log.names
            XCTAssertEqual(calls, allowed ? 1 : 0)
            XCTAssertEqual(names, allowed ? ["read_context"] : [])
        }
    }
    func testContainingFolderNeedsSeparateOpenApproval() async throws {
        let model = CountingModel(), log = Executions(), approvals = Executions()
        let context = FixtureTool(spec: .init("read_context", "fixture", fields: ["kind": "source"], capability: .context), result: .init(true, "Document", items: [.init(name: "file.txt", path: "/fixture/folder/file.txt", kind: "txt")]), log: log)
        let open = FixtureTool(spec: .init("open_path", "fixture", fields: ["path": "path"], capability: .openPath), result: .init(true, "Opened"), log: log)
        let agent = HybridAgentController(model: model, router: ToolRouter(tools: [context, open]))
        _ = try await agent.respond(decision: .deterministic(.contextFolder), history: [], configuration: .init(), onText: { _ in }, onEvent: { _ in }, authorize: { _, name, _ in await approvals.add(name); return name == "read_context" }, onResult: { _, _ in })
        let names = await log.names, asked = await approvals.names, calls = await model.calls
        XCTAssertEqual(names, ["read_context"]); XCTAssertEqual(asked, ["read_context", "open_path"]); XCTAssertEqual(calls, 0)
    }
    func testCachingBoundsAndQuotes() async throws {
        let cache=BoundedCache<String,Int>(capacity:2,ttl:.milliseconds(10));await cache.insert(1,for:"a");await cache.insert(2,for:"b");_ = await cache.value(for:"a");await cache.insert(3,for:"c")
        let evicted=await cache.value(for:"b");XCTAssertNil(evicted)
        try await Task.sleep(for:.milliseconds(20));let expired=await cache.value(for:"a");XCTAssertNil(expired)
        let router=FastIntentRouter();_ = await router.cachedRoute("open safari");let quoted=await router.cachedRoute("\"open safari\"");XCTAssertEqual(quoted,.requiresLLM)
    }
    func testSearchFiltersAndBackwardConfiguration() throws {
        XCTAssertEqual(FileSearchQuery.parse("PDFs named report").extensions,["pdf"])
        XCTAssertEqual(FileSearchQuery.parse("Python file named main").name,"main")
        XCTAssertEqual(FileSearchQuery.parse("recent presentations").extensions,["ppt","pptx","key"])
        XCTAssertNotNil(FileSearchQuery.parse("PDFs from last week").modifiedInterval())
        let config=try JSONDecoder().decode(ModelConfiguration.self,from:Data(#"{"model":"qwen3:8b","temperature":0.4,"contextWindow":4096,"maximumTokens":768,"timeout":120}"#.utf8))
        XCTAssertEqual(config.keepAliveSeconds,300);XCTAssertEqual(config.thinking,.automatic)
        XCTAssertFalse(ToolContextPolicy.needsTools("Don't open Safari"));XCTAssertFalse(ToolContextPolicy.needsTools("Write a binary search function"))
    }
    func testContextPreservesWholeLatestToolTurn() throws {
        var config=ModelConfiguration();config.contextWindow=2048;config.maximumTokens=768
        let history=[ChatMessage(role:"user",content:String(repeating:"old ",count:2000)),.init(role:"assistant",content:"old answer"),.init(role:"user",content:"Open Safari"),.init(role:"assistant",content:"",toolCalls:[ToolCall(name:"open_application",arguments:["application":.string("Safari")])]),.init(role:"tool",content:"Opened",toolName:"open_application")]
        let result=try ContextBudget.messages(history,system:"secure system",toolBytes:200,configuration:config)
        XCTAssertEqual(result.last?.role,"tool");XCTAssertEqual(result.filter{$0.role=="user"}.count,1);XCTAssertNotNil(result.first(where:{$0.tool_calls != nil}))
    }
}
