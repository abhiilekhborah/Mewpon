import XCTest
@testable import MewponCore
@testable import MewponDesktop
final class SpeedSearchTests: XCTestCase {
    static let commands = ["open safari", "opn safari", "vs cod", "find my cv", "fnd my cv pdf", "serch internship repot", "opn dwnloads", "btry lvl", "vol 30", "whr my resume pdf", "find the pdf with my education and projects", "open my recent python project", "opn latest py prj in vs cod", "dont open safari", "how can i open safari"]
    func testTyposAndSafety() async throws {
        let expected=["opn safari":"open_application","vs cod":"open_application","fnd my cv":"search_files","serch internship repot":"search_files","opn dwnloads":"open_path","btry lvl":"system_info","vol 30":"output_volume","whr my resume pdf":"search_files","opn last py proj":"python_project","opn latest py prj in vs cod":"python_project","find the pdf with my education and projects":"search_files"]
        for (input,name) in expected {guard case .deterministic(.tool(let call))=FastIntentRouter.classify(input) else{XCTFail(input);continue};XCTAssertEqual(call.function.name,name,input)}
        for input in ["dont opn safari","how to opn safari","how can i open safari","\"opn safari\"","opn safari and terminal","if opn safari","dont fnd cv"] {XCTAssertEqual(FastIntentRouter.classify(input),.requiresLLM,input);if input.hasPrefix("dont") || input.hasPrefix("how"){XCTAssertFalse(ToolContextPolicy.needsTools(input),input)}}
        XCTAssertTrue(DirectActionPolicy.permits(.deterministic(.rememberFileAlias(alias:"cv")),capability:.searchFiles,tool:"remember_file_alias",arguments:["path":.string("/fixture.pdf"),"alias":.string("cv")]))
        XCTAssertFalse(DirectActionPolicy.permits(.requiresLLM,capability:.searchFiles,tool:"remember_file_alias",arguments:["path":.string("/fixture.pdf"),"alias":.string("cv")]))
        XCTAssertEqual(FastIntentRouter.classify("open cv"),.deterministic(.searchAndOpen(query:"cv")))
        XCTAssertEqual(CommandVocabulary.distance("safrai","safari"),1)
        XCTAssertNil(CommandVocabulary.confident("cat",among:["car","bat"]))
        let router=FastIntentRouter()
        for path in ["/Users/Example/Report.PDF","/Users/Example/report.pdf","~/Documents/My File.pdf"] {
            let decision=await router.cachedRoute("open "+path)
            XCTAssertEqual(decision,.deterministic(.tool(.init(name:"open_path",arguments:["path":.string(path)]))))
        }
        XCTAssertEqual(FileSearchQuery.parse("resume pdf").extensions,["pdf"])
        XCTAssertEqual(FileSearchQuery.parse("ppt i made ystrday").extensions,["ppt","pptx","key"])
    }
    func testNativeTaskBenchmark() async throws {
        guard let output=ProcessInfo.processInfo.environment["MEWPON_TASK_OUTPUT"] else {throw XCTSkip("Opt-in native workflow benchmark")}
        let router=FastIntentRouter(),tools=ToolRouter(tools:[DateTimeTool(),CalculatorTool()])
        var rows:[[String:Any]]=[]
        for text in ["what time is it","calculate 145 * 23"] {for i in 0..<100 {
            let start=ContinuousClock.now
            guard case .deterministic(.tool(let call))=await router.cachedRoute(text) else{return XCTFail(text)}
            let dispatched=elapsedMilliseconds(since:start)
            let result=await tools.execute(call,authorize:{_,_,_ in false})
            XCTAssertTrue(result.success)
            rows.append(["input":text,"sample":i,"routing_to_dispatch_ms":dispatched,"native_end_to_end_ms":elapsedMilliseconds(since:start)])
        }}
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
    }
    func testRoutingBenchmark() async throws {
        guard let output=ProcessInfo.processInfo.environment["MEWPON_SPEED_OUTPUT"] else {throw XCTSkip("Opt-in benchmark")}
        let router=FastIntentRouter();var rows:[[String:Any]]=[]
        for text in Self.commands { for i in 0..<100 {
            let start=ContinuousClock.now;let decision=await router.cachedRoute(text)
            rows.append(["input":text,"sample":i,"ms":elapsedMilliseconds(since:start),"decision":String(describing:decision)])
        }}
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
    }
}
