import XCTest
import AppKit
@testable import MewponCore
@testable import MewponDesktop

private actor ExecutionRecorder {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
private struct NativeFixtureTool: AssistantTool {
    let spec: ToolSpec; let recorder: ExecutionRecorder
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult { await recorder.add(spec.name); return ToolResult(true, spec.name + " complete") }
}
private struct ForbiddenInference: LocalModelService {
    func chat(messages: [ChatMessage], tools: [ToolDefinition], configuration: ModelConfiguration, onText: @escaping @Sendable (String) async -> Void) async throws -> ChatMessage { XCTFail("A native plan must not call the model"); throw MewponError.invalid("Unexpected inference") }
}
final class Phase6Tests: XCTestCase {
    func testNativePlansAndTypoCommands() {
        for text in ["Volume 40", "volum 20", "Mute my Mac", "Bluetooth status", "Open display settings", "Dark mode", "Open my CV in Preview", "Open my latest Python project in VS Code", "Put Safari on the left and VS Code on the right", "Open Safari and open Terminal", "Move today's screenshots into a new folder", "Set my Mac for studying", "Open my project and start the development server", "Run workflow focus", "create folder /tmp/Example Folder"] {
            guard case .deterministic = FastIntentRouter.classify(text) else { XCTFail(text); continue }
        }
        for text in ["Don't mute my Mac", "How to open Safari and open Terminal", "Delete all my files", "Run rm -rf /", "Install unknown software", "Erase my disk"] {
            guard case .requiresLLM = FastIntentRouter.classify(text) else { XCTFail("Unsafe deterministic route: " + text); continue }
        }
    }
    func testTrustedCapabilitiesAndAlwaysReviewBoundary() {
        var policy = AutomationTrustPolicy()
        XCTAssertEqual(policy.evaluate(tool:"output_volume",arguments:["level":.string("40")]),.allow)
        XCTAssertEqual(policy.evaluate(tool:"open_application",arguments:[:]),.allow)
        XCTAssertEqual(policy.evaluate(tool:"file_operation",arguments:[:]),.ask)
        policy.rules[AutomationFeature.scripts.rawValue] = .allow
        policy.rules[AutomationFeature.context.rawValue] = .allow
        XCTAssertEqual(policy.evaluate(tool:"run_approved_workflow",arguments:[:]),.ask)
        XCTAssertEqual(policy.evaluate(tool:"read_context",arguments:[:]),.ask)
        policy.enabled=false
        XCTAssertEqual(policy.evaluate(tool:"output_volume",arguments:[:]),.deny)
    }
    func testFileScopeNoOverwriteNoDeleteAndSymlinkEscape() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:outside)}
        let source=root.appendingPathComponent("source.txt"),copy=root.appendingPathComponent("copy.txt"),moved=root.appendingPathComponent("moved.txt")
        try Data("controlled fixture".utf8).write(to:source)
        XCTAssertTrue(FileOperation.allowed(source.path,roots:[root.path]), "source=\(LocalPath.canonicalDestination(source.path)), root=\(LocalPath.canonical(root.path)), home=\(NSHomeDirectory())")
        XCTAssertTrue(FileOperation.allowed(copy.path,roots:[root.path]), "destination=\(LocalPath.canonicalDestination(copy.path)), source=\(LocalPath.canonicalDestination(source.path)), root=\(LocalPath.canonical(root.path))")
        XCTAssertTrue(try FileOperation(action:"copy",source:source.path,destination:copy.path).apply(roots:[root.path]).success)
        XCTAssertThrowsError(try FileOperation(action:"copy",source:source.path,destination:copy.path).apply(roots:[root.path]))
        XCTAssertTrue(try FileOperation(action:"move",source:copy.path,destination:moved.path).apply(roots:[root.path]).success)
        XCTAssertEqual(try Data(contentsOf:moved),Data("controlled fixture".utf8))
        XCTAssertThrowsError(try FileOperation(action:"delete",source:source.path,destination:moved.path).apply(roots:[root.path]))
        let directLink=root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at:directLink,withDestinationURL:source)
        XCTAssertThrowsError(try FileOperation(action:"copy",source:directLink.path,destination:root.appendingPathComponent("bad.txt").path).apply(roots:[root.path]))
        let link=root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        XCTAssertFalse(FileOperation.allowed(link.appendingPathComponent("new.txt").path,roots:[root.path]))
        XCTAssertFalse(FileOperation.allowed(root.appendingPathComponent(".env").path,roots:[root.path]))
    }
    func testSequentialPlanUsesNoInferenceAndStopsAfterDenial() async throws {
        let recorder=ExecutionRecorder()
        let tools:[any AssistantTool]=[
            NativeFixtureTool(spec:.init("open_application","Fixture",fields:["application":"App"],capability:.launchApplication),recorder:recorder),
            NativeFixtureTool(spec:.init("output_volume","Fixture",fields:["level":"Percent"],capability:.systemControl),recorder:recorder)
        ]
        let agent=HybridAgentController(model:ForbiddenInference(),router:ToolRouter(tools:tools))
        let decision=FastIntentRouter.classify("Open Safari and volume 20")
        _ = try await agent.respond(decision:decision,history:[],configuration:.init(),onText:{_ in},onEvent:{_ in},authorize:{_,_,_ in true},onResult:{_,_ in})
        let completed=await recorder.names
        XCTAssertEqual(completed,["open_application","output_volume"])
        let denied=ExecutionRecorder()
        let blocked=HybridAgentController(model:ForbiddenInference(),router:ToolRouter(tools:[NativeFixtureTool(spec:tools[0].spec,recorder:denied),NativeFixtureTool(spec:tools[1].spec,recorder:denied)]))
        _ = try await blocked.respond(decision:decision,history:[],configuration:.init(),onText:{_ in},onEvent:{_ in},authorize:{_,_,_ in false},onResult:{_,_ in})
        let names=await denied.names;XCTAssertTrue(names.isEmpty)
    }
    func testAllThemePalettesValidateAndUnsafeImportsFail() throws {
        XCTAssertEqual(MewponTheme.builtins.count,6)
        for theme in MewponTheme.builtins {
            XCTAssertEqual(try MewponTheme.validateImport(JSONEncoder().encode(theme)),theme)
            for p in [theme.light,theme.dark] { XCTAssertGreaterThanOrEqual(MewponTheme.contrast(p.text,p.background),4.5) }
        }
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(MewponTheme.builtins[0])) as! [String:Any]
        object["script"]="do anything"
        XCTAssertThrowsError(try MewponTheme.validateImport(JSONSerialization.data(withJSONObject:object)))
    }
    @MainActor func testThemeSwitchPreservesConversationTaskAndAvatarAndPersists() async throws {
        _ = NSApplication.shared
        let manager=ThemeManager.shared, prior=ThemeManager.shared.selectedID
        defer{try? manager.apply(prior)}
        let model=AssistantModel(startsServices:false)
        model.entries=[ChatEntry(role:"user",text:"Keep this conversation")];model.busy=true
        let palette=CommandPalette(model:model)
        palette.show()
        defer{palette.panel.orderOut(nil);model.avatar.exitPlayMode()}
        let avatar=model.avatar,web=avatar.webView,root=palette.panel.contentView
        avatar.enterPlayMode()
        palette.focus.request()
        for theme in MewponTheme.builtins {
            try manager.apply(theme.id);await Task.yield();palette.panel.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(palette.panel.firstResponder is CommandTextView, "Theme switching must preserve native editor focus")
            XCTAssertEqual(model.entries.count,1);XCTAssertTrue(model.busy);XCTAssertTrue(model.avatar === avatar);XCTAssertTrue(model.avatar.webView === web);XCTAssertTrue(avatar.isPlaying);XCTAssertTrue(palette.panel.contentView === root)
        }
        XCTAssertEqual(ThemeManager().selectedID,"developer")
        try manager.apply("liquid-glass")
        XCTAssertNil(manager.preferredScheme(appearance:"system"), "System appearance must not feed back the previous forced theme")
    }
    @MainActor func testRoutineAndWorkflowBoundaries() throws {
        XCTAssertEqual(try RoutineStore.calls(["Volume 20","Open Safari"]).count,2)
        XCTAssertThrowsError(try RoutineStore.calls(["Delete my files"]))
        XCTAssertThrowsError(try RoutineStore.calls(["Run workflow unknown"]))
        let root=URL(fileURLWithPath:"/tmp/phase6-project")
        let valid=Data(#"{"name":"Dev","executable":"/usr/bin/python3","arguments":["-I","-m","http.server","8000","--bind","127.0.0.1"],"directory":"/tmp/phase6-project"}"#.utf8)
        let workflow=try ApprovedWorkflow.decode(valid,base:root)
        XCTAssertNoThrow(try RunBuiltinServerTool().spec.validate(["plan":.string("fixture"),"preview":.string(workflow.preview)]))
        XCTAssertNoThrow(try RunApprovedWorkflowTool().spec.validate(["plan":.string("fixture"),"preview":.string(workflow.preview)]))
        XCTAssertThrowsError(try OpenApplicationTool().spec.validate(["application":.string("Safari\nTerminal")]))
        XCTAssertThrowsError(try ApprovedWorkflow.decode(Data(String(decoding:valid,as:UTF8.self).replacingOccurrences(of:"/usr/bin/python3",with:"/bin/sh").utf8),base:root))
    }
    func testWindowGeometryStaysOnSelectedDisplay() {
        let visible=CGRect(x:-1200,y:40,width:1200,height:800),current=CGRect(x:-1000,y:100,width:900,height:600)
        for action in ["left","right","center"] { XCTAssertTrue(visible.contains(WindowControlTool.target(action:action,current:current,visible:visible))) }
    }
    func testPlanSummaryIsPresentedOnce() {
        let entries=[ChatEntry(role:"user",text:"Open Safari and volume 55"),ChatEntry(role:"tool",text:"open_application",result:.init(true,"Opened Safari.")),ChatEntry(role:"tool",text:"output_volume",result:.init(true,"Output volume now 55%")),ChatEntry(role:"assistant",text:"Opened Safari.\nOutput volume now 55%")]
        XCTAssertEqual(PaletteTranscript.entries(entries).count,3)
        XCTAssertEqual(entries.count,4)
    }
    func testBluetoothPrivacyDescriptionIsPackaged() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist=try PropertyListSerialization.propertyList(from:Data(contentsOf:root.appendingPathComponent("AppInfo.plist")),format:nil) as! [String:Any]
        XCTAssertFalse((plist["NSBluetoothAlwaysUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertFalse((plist["NSAppleEventsUsageDescription"] as? String ?? "").isEmpty)
    }

    func testCompletedWorkflowDoesNotKeepPreviewAsFileResults() {
        let entries=[ChatEntry(role:"user",text:"Start my development server"),ChatEntry(role:"tool",text:"prepare_workflow",result:.init(true,"Preview",items:[.init(name:"Development",path:"/fixture",kind:"safe-workflow-plan:fixture")])),ChatEntry(role:"tool",text:"run_builtin_server",result:.init(false,"Workflow exited with status 1.")),ChatEntry(role:"assistant",text:"Workflow exited with status 1.")]
        XCTAssertEqual(PalettePresentation.resolve(input:"",entries:entries,busy:false),.confirmation)
    }

    func testAppearanceWordingBypassesInferenceWithOversizedHistory() async throws {
        for text in ["Change to dark mode", "Switch to dark mode", "Please change it to dark mode.", "Can you switch my Mac to light mode?", "Could you change macOS to dark mode", "Turn on light mode"] {
            let recorder=ExecutionRecorder()
            let tool=NativeFixtureTool(spec:SystemAppearanceTool().spec,recorder:recorder)
            let agent=HybridAgentController(model:ForbiddenInference(),router:ToolRouter(tools:[tool]))
            let history=[ChatMessage(role:"user",content:String(repeating:"old tool context ",count:5000)),.init(role:"assistant",content:String(repeating:"old result ",count:5000)),.init(role:"user",content:text)]
            let result=try await agent.respond(decision:FastIntentRouter.classify(text),history:history,configuration:.init(),onText:{_ in},onEvent:{_ in},authorize:{_,_,_ in true},onResult:{_,_ in})
            let names=await recorder.names
            XCTAssertEqual(names,["system_appearance"],text)
            XCTAssertEqual(result.last?.content,"system_appearance complete")
        }
        for text in ["Don't change to dark mode", "How do I change to dark mode?", "Change to dark mode if Safari is open", "Change to dark mode and delete my files", "Explain how to switch to dark mode"] {
            XCTAssertEqual(FastIntentRouter.classify(text),.requiresLLM,text)
        }
    }
    func testFallbackToolCatalogFitsLocalContextAndKeepsAppearanceTool() throws {
        var available=[SystemAppearanceTool().spec.definition,ThemeTool().spec.definition,SystemSettingsTool().spec.definition,OpenApplicationTool().spec.definition,FileSearchTool().spec.definition,OpenFileTool().spec.definition,SystemInfoTool().spec.definition,DateTimeTool().spec.definition,CalculatorTool().spec.definition]
        // Reproduce the full-catalog pressure independently of future tool count.
        available += (0..<40).map { ToolDefinition(name:"unrelated_\($0)",description:String(repeating:"Unrelated tool description. ",count:30),fields:["argument":"Input"]) }
        let prompt="Would you change the appearance of my Mac to dark mode for me?"
        let selected=ToolCatalog.select(prompt:prompt,available:available,configuration:.init())
        XCTAssertTrue(selected.contains { $0.function.name == "system_appearance" })
        XCTAssertLessThanOrEqual(selected.count,8)
        let history=[ChatMessage(role:"user",content:String(repeating:"old context ",count:5000)),.init(role:"assistant",content:"old answer"),.init(role:"user",content:prompt)]
        let bytes=try JSONEncoder().encode(selected).count
        XCTAssertNoThrow(try ContextBudget.messages(history,system:AgentController.systemPrompt,toolBytes:bytes,configuration:.init()))
        XCTAssertThrowsError(try ContextBudget.messages(history,system:AgentController.systemPrompt,toolBytes:JSONEncoder().encode(available).count,configuration:.init()))
        XCTAssertTrue(ToolCatalog.select(prompt:"Explain dark mode",available:available,configuration:.init()).isEmpty)
    }

}
