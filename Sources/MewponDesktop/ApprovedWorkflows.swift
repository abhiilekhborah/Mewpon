import AppKit
import SwiftUI
import CryptoKit
import MewponCore

struct ApprovedWorkflow: Codable, Equatable, Identifiable, Sendable {
    var id: String { name.lowercased() }
    let name: String; let executable: String; let arguments: [String]; let directory: String
    static let programs: Set<String> = ["/usr/bin/python3", "/opt/homebrew/bin/node", "/usr/local/bin/node", "/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/shortcuts"]
    static func read(_ url: URL) throws -> Data {
        let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile==true, values.isSymbolicLink != true, (values.fileSize ?? Int.max)<=900 else{throw MewponError.invalid("Choose a regular workflow JSON under 900 bytes.")}
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        let data=try handle.read(upToCount:901) ?? Data()
        guard data.count<=900 else{throw MewponError.invalid("Workflow file grew beyond its limit.")}
        return data
    }
    static func decode(_ data: Data, base: URL) throws -> Self {
        guard data.count <= 900, let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(dict.keys) == ["name","executable","arguments","directory"] else { throw MewponError.invalid("Use a workflow JSON with name, executable, arguments, directory; limit 900 bytes.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.name.isEmpty, value.name.count <= 60, programs.contains(value.executable), value.arguments.count <= 16, value.arguments.allSatisfy({ !$0.contains("\u{0}") && $0.count <= 128 }), !value.arguments.contains(where:{["-c","-e","--eval"].contains($0)}), LocalPath.canonicalDestination(value.directory) == LocalPath.canonicalDestination(base.path), base.path != NSHomeDirectory(), URL(fileURLWithPath:LocalPath.canonicalDestination(base.path)).pathComponents.count > 3 else { throw MewponError.invalid("Choose an allowed program and the manifest's project folder. Shells, inline code, privileged commands, and outside working directories are blocked.") }
        return value
    }
    var isBuiltinServer: Bool {
        executable == "/usr/bin/python3" && arguments.count == 6 && Array(arguments.prefix(3)) == ["-I", "-m", "http.server"] && Int(arguments[3]).map { (1024...65535).contains($0) } == true && Array(arguments.suffix(2)) == ["--bind", "127.0.0.1"]
    }
    var preview: String { "Run \(executable) \(arguments.joined(separator: " "))\nWorking folder: \(directory)\n" + (isBuiltinServer ? "Isolated Python localhost server. No project scripts execute." : "Unknown project code may execute. Review every run.") }
}
@MainActor final class ApprovedWorkflowStore: ObservableObject {
    static let shared = ApprovedWorkflowStore()
    @Published private(set) var manifests: [String]
    @Published var issue: String?
    init() { manifests = UserDefaults.standard.stringArray(forKey: "approvedWorkflowManifests") ?? [] }
    func add() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.message = "Choose a project workflow manifest. Executing it always requires a separate review."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try ApprovedWorkflow.decode(ApprovedWorkflow.read(url), base: url.deletingLastPathComponent())
            if !manifests.contains(url.path) { manifests.append(url.path); UserDefaults.standard.set(manifests, forKey: "approvedWorkflowManifests") }; issue = nil
        } catch { issue = error.localizedDescription }
    }
    func createPythonServer() {
        let picker=NSOpenPanel();picker.canChooseDirectories=true;picker.canChooseFiles=false
        picker.message="Choose a project folder for an isolated Python server bound only to this Mac (127.0.0.1:8000). No project scripts will execute."
        guard picker.runModal() == .OK,let folder=picker.url else{return}
        do {
            let workflow=ApprovedWorkflow(name:"Development server",executable:"/usr/bin/python3",arguments:["-I","-m","http.server","8000","--bind","127.0.0.1"],directory:folder.resolvingSymlinksInPath().path)
            let data=try JSONEncoder().encode(workflow)
            _ = try ApprovedWorkflow.decode(data,base:folder)
            let url=folder.appendingPathComponent(".mewpon-development.json")
            try data.write(to:url,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            manifests.append(url.path);UserDefaults.standard.set(manifests,forKey:"approvedWorkflowManifests");issue=nil
        }catch{issue=error.localizedDescription}
    }
    func remove(_ path: String) { manifests.removeAll{$0 == path}; UserDefaults.standard.set(manifests, forKey: "approvedWorkflowManifests") }
}
actor WorkflowPlans {
    static let shared = WorkflowPlans()
    struct Plan: Sendable { let created: Date; let path: String; let digest: String; let workflow: ApprovedWorkflow }
    private var plans: [String: Plan] = [:]
    func prepare(paths: [String], name: String) throws -> ToolResult {
        let values = paths.compactMap { path -> (String, Data, ApprovedWorkflow)? in
            guard let data = try? ApprovedWorkflow.read(URL(fileURLWithPath: path)), let workflow = try? ApprovedWorkflow.decode(data, base: URL(fileURLWithPath: path).deletingLastPathComponent()), (name == "development" && workflow.name.lowercased().contains("development")) || workflow.name.caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return (path, data, workflow)
        }
        guard values.count == 1, let value = values.first else { return ToolResult(false, values.isEmpty ? "Choose and review a workflow manifest in Settings → Permissions first." : "Several workflows match; use one exact saved workflow name.") }
        plans = plans.filter{Date().timeIntervalSince($0.value.created)<300}
        guard plans.count < 8 else { return ToolResult(false,"Too many pending workflow previews.") }
        let id=UUID().uuidString
        plans[id] = .init(created:Date(),path:value.0,digest:SHA256.hash(data:value.1).map{String(format:"%02x",$0)}.joined(),workflow:value.2)
        return ToolResult(true,value.2.preview,items:[ResultItem(name:value.2.name,path:value.2.directory,kind:(value.2.isBuiltinServer ? "safe-workflow-plan:" : "workflow-plan:")+id)])
    }
    func consume(_ id:String, registered:[String]) throws -> ApprovedWorkflow {
        guard let plan=plans.removeValue(forKey:id),Date().timeIntervalSince(plan.created)<300,registered.contains(plan.path),let data=try? ApprovedWorkflow.read(URL(fileURLWithPath:plan.path)),SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==plan.digest else {throw MewponError.invalid("Workflow changed, expired, or was revoked. Prepare and review it again.")}
        return try ApprovedWorkflow.decode(data,base:URL(fileURLWithPath:plan.path).deletingLastPathComponent())
    }
}
@MainActor final class WorkflowProcesses {
    static let shared=WorkflowProcesses()
    private var processes:[String:Process]=[:]
    func start(_ workflow:ApprovedWorkflow) async throws ->ToolResult {
        if processes[workflow.directory]?.isRunning == true {return ToolResult(false,"A managed workflow is already running in this project. Nothing started twice.")}
        guard processes.values.filter(\.isRunning).count<3 else{return ToolResult(false,"Stop a managed workflow before starting another.")}
        let process=Process();process.executableURL=URL(fileURLWithPath:workflow.executable);process.arguments=workflow.arguments;process.currentDirectoryURL=URL(fileURLWithPath:workflow.directory)
        process.environment=["PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin","HOME":NSHomeDirectory(),"LANG":"en_US.UTF-8"]
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try Task.checkCancellation();try process.run();processes[workflow.directory]=process
        do { try await Task.sleep(for:.milliseconds(150)) } catch { if process.isRunning { process.terminate() }; throw error }
        if Task.isCancelled{process.terminate();throw CancellationError()}
        if !process.isRunning {return ToolResult(process.terminationStatus==0,"Workflow exited with status \(process.terminationStatus).")}
        return ToolResult(true,"Started \(workflow.name) (PID \(process.processIdentifier)). The process is running; server readiness has not been verified.")
    }
    func stopAll() {for process in processes.values where process.isRunning {process.terminate()};processes.removeAll()}
}
struct PrepareWorkflowTool:AssistantTool {
    let spec=ToolSpec("prepare_workflow","Prepare a frozen preview of one user-registered workflow; never executes code.",fields:["name":"Exact saved workflow name, or development"],capability:.routine)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        let paths=await MainActor.run{ApprovedWorkflowStore.shared.manifests}
        return try await WorkflowPlans.shared.prepare(paths:paths,name:arguments["name"]!.string!)
    }
}
struct RunApprovedWorkflowTool:AssistantTool {
    let spec=ToolSpec("run_approved_workflow","Run only a frozen, registered workflow after individual confirmation. Never accept arbitrary shell commands or an unregistered executable.",fields:["plan":"Exact workflow preview ID","preview":"Exact human-readable executable, arguments, and project preview"],capability:.externalAutomation,timeout:30,multilineFields:["preview"])
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        let paths=await MainActor.run{ApprovedWorkflowStore.shared.manifests}
        let workflow=try await WorkflowPlans.shared.consume(arguments["plan"]!.string!,registered:paths)
        guard arguments["preview"]!.string! == workflow.preview else {return ToolResult(false,"The approved preview does not match this workflow. Nothing ran.")}
        return try await WorkflowProcesses.shared.start(workflow)
    }
}
struct WorkflowSettings:View {
    @ObservedObject private var store=ApprovedWorkflowStore.shared
    var body:some View {
        Section("Reviewed development workflows") {
            Text("Register a local project JSON with name, executable, arguments, and directory. The directory must be the manifest's folder. Custom program runs always require an exact preview and confirmation. The built-in isolated Python localhost server can use the trusted-routines policy.").font(.caption)
            Button("Configure Python localhost server…"){store.createPythonServer()}
            Button("Add workflow manifest…"){store.add()}
            ForEach(store.manifests,id:\.self){path in HStack{Text(path).font(.caption);Spacer();Button("Revoke"){store.remove(path)}}}
            Button("Stop managed workflows"){WorkflowProcesses.shared.stopAll()}
            if let issue=store.issue{Text(issue).font(.caption).foregroundStyle(.orange)}
        }
    }
}

struct OpenWorkflowProjectTool: AssistantTool {
    let spec=ToolSpec("open_workflow_project","Open only the working directory of a user-registered workflow in VS Code. Does not execute code.",fields:["path":"Exact registered working folder"],capability:.openPath)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        let paths=await MainActor.run{ApprovedWorkflowStore.shared.manifests}
        let directory=URL(fileURLWithPath:arguments["path"]!.string!).resolvingSymlinksInPath().path
        let known=paths.contains { path in
            guard let data=try? ApprovedWorkflow.read(URL(fileURLWithPath:path)),let workflow=try? ApprovedWorkflow.decode(data,base:URL(fileURLWithPath:path).deletingLastPathComponent()) else{return false}
            return URL(fileURLWithPath:workflow.directory).resolvingSymlinksInPath().path==directory
        }
        guard known else{return ToolResult(false,"This folder is not a registered workflow project.")}
        let apps=try await OpenApplicationTool.resolve("vscode")
        guard apps.count==1 else{return ToolResult(false,"Choose the intended VS Code installation.",items:apps)}
        return try await NativeWorkspaceOpen.openProject(URL(fileURLWithPath:directory),editor:URL(fileURLWithPath:apps[0].path))
    }
}

struct RunBuiltinServerTool: AssistantTool {
    let spec=ToolSpec("run_builtin_server","Start only the registered built-in isolated Python HTTP server bound to 127.0.0.1. No project script or arbitrary arguments.",fields:["plan":"Exact prepared workflow ID","preview":"Exact preview"],capability:.routine,timeout:30,multilineFields:["preview"])
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        let paths=await MainActor.run{ApprovedWorkflowStore.shared.manifests}
        let workflow=try await WorkflowPlans.shared.consume(arguments["plan"]!.string!,registered:paths)
        guard workflow.isBuiltinServer,workflow.preview==arguments["preview"]!.string! else{return ToolResult(false,"This is not the exact registered built-in localhost server. Nothing ran.")}
        return try await WorkflowProcesses.shared.start(workflow)
    }
}
