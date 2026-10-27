import AppKit
import SwiftUI
import MewponCore
import UniformTypeIdentifiers

struct PermissionRequest: Identifiable {
    let id: UUID
    let capability: Capability
    let tool: String
    let arguments: [String: JSONValue]
}

@MainActor final class PermissionManager: ObservableObject {
    @Published private(set) var pending: PermissionRequest?
    @Published private(set) var lastDecision: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var denied: Set<Capability> = []
    func beginRequest() { denied.removeAll() }
    func authorize(_ capability: Capability, tool: String, arguments: [String: JSONValue]) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            guard continuation == nil, !Task.isCancelled, !denied.contains(capability) else { return false }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                pending = PermissionRequest(id: id, capability: capability, tool: tool, arguments: arguments)
            }
        } onCancel: { Task { @MainActor in if self.pending?.id == id { self.resolve(false) } } }
    }
    func resolve(_ approved: Bool, requestID: UUID? = nil) {
        guard let request = pending, requestID == nil || request.id == requestID else { return }
        lastDecision = approved
        // Detach the continuation before publishing dismissal: sheet callbacks can reenter.
        let continuation = self.continuation; self.continuation = nil
        if !approved, let capability = pending?.capability { denied.insert(capability) }
        pending = nil
        continuation?.resume(returning: approved)
    }
}

struct ChatEntry: Identifiable {
    let id: UUID
    let role: String
    var text: String
    var result: ToolResult?
    init(role: String, text: String, result: ToolResult? = nil, id: UUID = UUID()) { self.id = id; self.role = role; self.text = text; self.result = result }
}

@MainActor final class AssistantModel: ObservableObject {
    @Published var paused = false { didSet { if paused { voice.stop(); meetings.cancel(); proactive.pause(); reminders.paused=true; Task{await reminders.schedule()} } } }
    @Published var expanded = false
    @Published var input = ""
    @Published var droppedText: String?
    @Published var entries: [ChatEntry] = []
    @Published var busy = false
    @Published var ready = false
    @Published var directActions = UserDefaults.standard.object(forKey: "directActions") as? Bool ?? true { didSet { UserDefaults.standard.set(directActions, forKey: "directActions") } }
    @Published var preloadEnabled = UserDefaults.standard.object(forKey: "preloadModel") as? Bool ?? true { didSet { UserDefaults.standard.set(preloadEnabled, forKey: "preloadModel"); schedulePreload() } }
    @Published private(set) var preloadStatus = "Not started"
    private var preloadTask: Task<Void, Never>?
    private var preloadRefresh: Task<Void, Never>?
    private var preloadConfiguration: ModelConfiguration?
    private var warmedAt: ContinuousClock.Instant?
    private var preloadGeneration = UUID()
    private var startsModelServices = false
    private var inferenceConfiguration: ModelConfiguration?
    @Published var connectionStatus = "Not checked"
    @Published var status = "Local by design"
    @Published var issue: String?
    @Published var models: [OllamaModel] = []
    @Published var firstTokenLatency: Double?
    @Published var focusRequest = 0
    @Published var composerHeight: CGFloat = 48 { didSet { if expanded { onResize?(true) } } }
    @Published var screenHeight: CGFloat = 900
    var transcriptHeight: CGFloat {
        min(entries.isEmpty ? 204 : 340, max(100, screenHeight - 158 - 68 - composerHeight - 68 - (issue == nil && avatar.error == nil ? 0 : 62)))
    }
    var windowHeight: CGFloat { 158 + 68 + transcriptHeight + composerHeight + 48 + (issue == nil && avatar.error == nil ? 0 : 62) }
    @Published var configuration: ModelConfiguration {
        didSet { if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: "modelConfiguration") }; if oldValue != configuration { schedulePreload() } }
    }
    @Published var historyEnabled = UserDefaults.standard.bool(forKey: "historyEnabled")
    let avatar = AvatarBridge()
    let permissions = PermissionManager()
    let reminders = ReminderLibrary()
    let calendar = CalendarAccess()
    let contacts = ContactAccess()
    lazy var proactive=ProactiveAssistant(reminders:reminders,calendar:calendar)
    let meetings = MeetingLibrary()
    let voice = VoiceAssistant()
    let automation = AutomationPreferences()
    @Published var paletteVisible = false
    let service: OllamaService
    private let intents=FastIntentRouter()
    private func makeRouter(request:UUID)->ToolRouter {
        let roots: @Sendable () async -> [String] = { [weak self] in await self?.operationFolders() ?? [] }
        return ToolRouter(tools:[TranslationTool(),UnitConversionTool(),TimeZoneTool(),WeatherTool(),OnlineNewsTool(),OpenURLTool(),DueWeekTool(),ContactQueryTool(),LocalRemindersTool(),CalendarQueryTool(),CalendarWriteTool(),VoiceOutputTool(),AssistantWorkspaceTool(),OpenApplicationTool(),PythonProjectTool(),OpenProjectTool(),RememberFileAliasTool(),FileSearchTool(onProgress:{[weak self] result in await self?.receiveSearchProgress(result,request:request)}),OpenFileTool(),FinderActionTool(),ReadDocumentTool(),ScreenTextTool(),ContextTool(),ApplicationControlTool(),VolumeTool(),WiFiStatusTool(),SystemSettingsTool(),SystemInfoTool(),DateTimeTool(),CalculatorTool(),PrepareWorkflowTool(),RunBuiltinServerTool(),RunApprovedWorkflowTool(),OpenWorkflowProjectTool(),ThemeTool(),MediaControlTool(),MinimizeOtherWindowsTool(),AudioControlTool(),DisplayControlTool(),BluetoothStatusTool(),SystemAppearanceTool(),PowerControlTool(),WindowControlTool(),FileOperationTool(roots: roots),PrepareScreenshotsTool(roots: roots),ApplyFileBatchTool(roots: roots),OpenDocumentWithTool(),OpenSelectedDocumentWithTool(),LatestPythonProjectTool(),SavedRoutineTool(run: { [weak self] name in
            guard let self else { throw CancellationError() }
            return try await self.runRoutine(name, request: request)
        })], canExecute: { [weak self] _ in await self?.automationEnabled() ?? false })
    }
    private func operationFolders() -> [String] { automation.policy.folders }
    private func automationEnabled() -> Bool { automation.policy.enabled }
    private func authorizeAction(_ capability: Capability, tool: String, arguments: [String: JSONValue]) async -> Bool {
        if AutomationTrustPolicy.feature(tool:tool,arguments:arguments) == .network,OnlineIntentScope.forbidsNetwork(entries.last(where:{$0.role=="user"})?.text ?? ""){return false}
        switch automation.policy.evaluate(tool: tool, arguments: arguments) {
        case .deny: return false
        case .allow where directActions:
            if AutomationTrustPolicy.feature(tool:tool,arguments:arguments) == .network {
                let request=entries.last(where:{$0.role=="user"})?.text ?? ""
                guard !OnlineIntentScope.forbidsNetwork(request) else{return false}
                if !OnlineIntentScope.covers(tool:tool,arguments:arguments,request:request){return await permissions.authorize(capability,tool:tool,arguments:arguments)}
            }
            return true
        default: return await permissions.authorize(capability, tool: tool, arguments: arguments)
        }
    }
    private func runRoutine(_ name: String, request: UUID) async throws -> ToolResult {
        guard let routine = RoutineStore.shared.routines.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return ToolResult(false, "Save and review this routine in Settings → Permissions first.") }
        let calls = try RoutineStore.calls(routine.commands)
        let router = makeRouter(request: request)
        var summaries: [String] = []
        for call in calls {
            try Task.checkCancellation()
            let result = await router.execute(call, authorize: { [weak self] capability, tool, arguments in
                await self?.authorizeAction(capability, tool: tool, arguments: arguments) ?? false
            })
            await receiveResult(call.function.name, result, request: request)
            summaries.append(result.summary)
            if !result.success { return ToolResult(false, summaries.joined(separator: "\n")) }
        }
        return ToolResult(true, summaries.joined(separator: "\n"))
    }
    private var searchProgressID:UUID?
    private let store: ConversationStore
    private var conversation = Conversation()
    private var generation: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var activeRequest: UUID?
    private var draftID: UUID?
    private var requestFailed = false
    private var startedAt: ContinuousClock.Instant?
    private var streamBuffer = ""
    private var streamFlush: Task<Void, Never>?
    var onFinished: ((Bool, Double) -> Void)?
    var onResize: ((Bool) -> Void)?
    var onActivate: (() -> Void)?
    init(startsServices: Bool = true, storageDirectory: URL? = nil, service: OllamaService = OllamaService()) {
        self.service = service
        if let data = UserDefaults.standard.data(forKey: "modelConfiguration"), let config = try? JSONDecoder().decode(ModelConfiguration.self, from: data), (try? config.validated()) != nil { configuration = config }
        else { configuration = ModelConfiguration() }
        let root = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Mewpon", isDirectory: true)
        store = ConversationStore(directory: root)
        automation.disabled = { [weak self] in self?.cancel(); self?.voice.stop(); self?.meetings.cancel(); self?.proactive.pause(); self?.reminders.paused=true; Task{await self?.reminders.schedule()} }
        guard startsServices else { ready = true; return }
        proactive.start()
        startsModelServices = true
        // Start preparing the model independently of disk history and connection UI.
        schedulePreload()
        Task { await refreshModels() }
        ready = !historyEnabled
        Task {
            do {
                if historyEnabled { conversation = try await store.load(); rebuildEntries() }
                else { try await store.clear() }
            } catch { issue = "History: " + error.localizedDescription }
            ready = true
        }
    }
    func schedulePreload(force: Bool = false) {
        guard startsModelServices else { return }
        preloadRefresh?.cancel(); preloadRefresh = nil
        let config = configuration
        guard preloadEnabled, config.keepAliveSeconds > 0 else {
            interruptPreload(); warmedAt = nil; preloadConfiguration = nil; preloadStatus = "Off"; return
        }
        if preloadConfiguration != config {
            interruptPreload(); warmedAt = nil; preloadConfiguration = config
        }
        guard !busy else { preloadStatus = "Deferred while working"; return }
        // Model listings, window activation and settings refresh must not restart an in-flight load.
        guard preloadTask == nil else { return }
        let refreshAfter = Double(config.keepAliveSeconds) * 0.75
        if !force, let warmedAt {
            let remaining = refreshAfter - elapsedMilliseconds(since: warmedAt) / 1000
            if remaining > 0 { scheduleWarmRefresh(after: remaining); return }
        }
        let id = UUID(); preloadGeneration = id
        preloadStatus = "Preparing first response in background…"
        preloadTask = Task {
            do {
                let lease=try await InferenceScheduler.shared.begin(wait:false)
                defer{Task{await InferenceScheduler.shared.end(lease)}}
                try await service.preload(configuration: config)
                try Task.checkCancellation()
                try await service.primeChat(configuration: config)
                try Task.checkCancellation()
                guard preloadGeneration == id else { return }
                warmedAt = .now; preloadTask = nil
                preloadStatus = "Ready · model and chat prompt warmed"
                scheduleWarmRefresh(after: refreshAfter)
            } catch {
                guard preloadGeneration == id else { return }
                preloadTask = nil
                if !(error is CancellationError) {
                    preloadStatus = "Warm-up unavailable · tasks can still retry"
                    scheduleWarmRefresh(after: 30)
                }
            }
        }
    }
    func auxiliaryModelFinished(_ name:String) {
        guard name != configuration.model else{return}
        warmedAt=nil;preloadStatus="Preparing the chat model after local translation…"
        if !busy{schedulePreload()}
    }
    private func scheduleWarmRefresh(after seconds: Double) {
        preloadRefresh?.cancel()
        preloadRefresh = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(1, seconds)))
                self?.schedulePreload()
            } catch { }
        }
    }
    private func interruptPreload() {
        preloadGeneration = UUID()
        preloadTask?.cancel(); preloadTask = nil
        preloadRefresh?.cancel(); preloadRefresh = nil
    }
    func expand() { expanded = true; onResize?(true); onActivate?(); focusRequest += 1 }
    func collapse() { expanded = false; onResize?(false) }
    func typing() { if !busy { avatar.event(input.isEmpty ? .idle : .typing) } }
    func refreshModels() async {
        do { models = try await service.models(forceRefresh:true); status = models.isEmpty ? "No local models installed" : "Ollama connected"; connectionStatus = "Last check: connected"; issue = nil }
        catch { connectionStatus = "Last check: unavailable"; status = "Ollama unavailable"; issue = error.localizedDescription }
    }
    func submit() {
        let acknowledgementStart=ContinuousClock.now
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !paused, !busy, !text.isEmpty else { return }
        guard text.count <= 4000 else { issue = "Please keep each message under 4000 characters."; return }
        input = ""; issue = nil; busy = true; firstTokenLatency = nil; startedAt = .now
        let id = UUID(); activeRequest = id
        permissions.beginRequest(); requestFailed = false
        conversation.append(ChatMessage(role: "user", content: text))
        entries.append(ChatEntry(role: "user", text: text))
        if expanded { onResize?(true) }
        avatar.event(.thinking); status = "Recognizing command…"
        let acknowledgedMs=elapsedMilliseconds(since:acknowledgementStart)
        Task{await PerformanceProfiler.shared.record("ui.submit_assignment",milliseconds:acknowledgedMs)}
        let config = configuration
        let history = conversation.messages
        generation = Task {
            var inferenceLease:UUID?
            defer { if let inferenceLease { Task { await InferenceScheduler.shared.end(inferenceLease) } }; if activeRequest == id { finishRequest() } }
            do {
                let routeStart=ContinuousClock.now
                let decision=await intents.cachedRoute(text)
                await PerformanceProfiler.shared.record("input.routing",since:routeStart)
                try Task.checkCancellation()
                if case .requiresLLM=decision {interruptPreload();status="Waiting for local inference…";inferenceLease = try await InferenceScheduler.shared.begin();inferenceConfiguration = config; avatar.setInferenceActive(true,adaptive:config.adaptiveAvatar);status="Connecting to local model…";_ = try config.validated();try await service.ensureModel(config.model)}
                else {status="Running native command…"}
                let agent = HybridAgentController(model: service, router: makeRouter(request:id))
                let produced = try await agent.respond(decision:decision,history: history, configuration: config,
                    onText: { [weak self] text in await self?.receive(text, request: id) },
                    onEvent: { [weak self] event in await self?.receive(event, request: id) },
                    authorize: { [weak self] capability, tool, arguments in
                        guard let self else { return false }
                        return await self.authorizeAction(capability, tool: tool, arguments: arguments)
                    },
                    onResult: { [weak self] name, result in await self?.receiveResult(name, result, request: id) })
                try Task.checkCancellation()
                flushStream()
                firstTokenLatency = produced.compactMap(\.firstTokenSeconds).first ?? firstTokenLatency
                conversation.append(contentsOf: produced)
                if produced.last?.content.isEmpty == true { entries.append(ChatEntry(role: "assistant", text: "The model returned an empty response. Try again with a shorter question.")) }
                if case .requiresLLM=decision {avatar.event(.responding, returnToIdle:true)}
                else {avatar.event(requestFailed ? .failure:.success,returnToIdle:true)}
                status = "Ready"; saveHistory()
            } catch is CancellationError {
                flushStream(); status = "Cancelled"; avatar.event(.idle)
                recordInterrupted("Request cancelled.")
            } catch {
                flushStream(); issue = error.localizedDescription; status = "Needs attention"; avatar.event(.failure, returnToIdle: true)
                recordInterrupted("Request stopped: " + error.localizedDescription)
            }
        }
    }
    private func receive(_ text: String, request: UUID) {
        guard activeRequest == request, !Task.isCancelled else { return }
        let first=firstTokenLatency == nil
        if first, let startedAt { firstTokenLatency = elapsedMilliseconds(since:startedAt)/1000; avatar.event(.responding) }
        streamBuffer += text
        if first {flushStream();return}
        if streamFlush == nil {
            streamFlush = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(40)); self?.flushStream() } catch {}
            }
        }
    }
    private func flushStream() {
        streamFlush?.cancel(); streamFlush = nil
        guard !streamBuffer.isEmpty else { return }
        let updateStart=ContinuousClock.now
        if let draftID, let index = entries.firstIndex(where: { $0.id == draftID }) { entries[index].text += streamBuffer }
        else { let entry = ChatEntry(role: "assistant", text: streamBuffer); entries.append(entry); draftID = entry.id }
        streamBuffer = ""
        let updateMs=elapsedMilliseconds(since:updateStart)
        Task{await PerformanceProfiler.shared.record("ui.text_assignment",milliseconds:updateMs)}
    }
    private func receiveSearchProgress(_ result:ToolResult,request:UUID){
        guard activeRequest==request,busy else{return}
        if let searchProgressID,let index=entries.firstIndex(where:{$0.id==searchProgressID}){entries[index].result=result}
        else {let entry=ChatEntry(role:"tool",text:"Searching indexed files…",result:result);searchProgressID=entry.id;entries.append(entry)}
    }
    private func receive(_ event: AssistantEvent, request: UUID) {
        guard activeRequest == request else { return }
        flushStream()
        if event == .thinking { avatar.setInferenceActive(true, adaptive: configuration.adaptiveAvatar); draftID = nil; status = "Generating locally…" }
        else { status = event == .searching ? "Searching indexed files…" : "Checking action…" }
        avatar.event(event)
    }
    private func receiveResult(_ name: String, _ result: ToolResult, request: UUID) async {
        automation.record(name, success: result.success)
        guard activeRequest == request else { return }
        requestFailed = requestFailed || !result.success
        flushStream(); draftID = nil
        if name=="search_files",let searchProgressID,let index=entries.firstIndex(where:{$0.id==searchProgressID}){entries[index]=ChatEntry(role:"tool",text:"search files",result:result,id:searchProgressID);self.searchProgressID=nil}
        else {entries.append(ChatEntry(role: "tool", text: name.replacingOccurrences(of: "_", with: " "), result: result))}
        avatar.event(result.success ? .success : .failure)
        do { try await store.log(tool: name, success: result.success) } catch { issue = "Could not write the local action log: " + error.localizedDescription }
    }
    private func recordInterrupted(_ reason: String) {
        // Keep actual results in context after an interrupted generation, without incomplete tool-call sequences.
        let afterUser = entries.lastIndex(where: { $0.role == "user" }) ?? 0
        let results = entries.dropFirst(afterUser).compactMap { $0.result?.json }.joined(separator: "\n")
        conversation.append(ChatMessage(role: "assistant", content: reason + (results.isEmpty ? "" : "\nActual tool results (untrusted data):\n" + results)))
        saveHistory()
    }
    private func finishRequest() {
        if inferenceConfiguration == configuration, inferenceConfiguration != nil, issue == nil, !Task.isCancelled {
            preloadConfiguration = configuration; warmedAt = .now
            preloadStatus = "Ready · model and chat prompt warmed"
        }
        inferenceConfiguration = nil
        avatar.setInferenceActive(false)
        if let startedAt, !Task.isCancelled { onFinished?(issue != nil || requestFailed, elapsedMilliseconds(since: startedAt) / 1000) }; startedAt = nil
        var usage=rusage();if getrusage(RUSAGE_SELF,&usage)==0{let bytes=Int64(usage.ru_maxrss);Task{await PerformanceProfiler.shared.recordPeakResidentBytes(bytes)}}
        searchProgressID=nil
        while entries.count>120,let next=entries.dropFirst().firstIndex(where:{$0.role=="user"}){entries.removeFirst(next)}
        busy = false; generation = nil; activeRequest = nil; draftID = nil; streamFlush?.cancel(); streamFlush = nil; if expanded { onResize?(true) }; schedulePreload() }
    func cancel() { generation?.cancel(); permissions.resolve(false) }
    func shutdown() { startsModelServices = false; interruptPreload(); cancel(); voice.stop(); meetings.cancel(); proactive.stop() }
    func retry() {
        guard !busy, let last = conversation.messages.last(where: { $0.role == "user" }) else { return }
        input = last.content; focusRequest += 1
    }
    func newConversation() {
        guard !busy else { return }
        DroppedContent.shared.cleanup(); droppedText = nil
        conversation.clear(); entries = []; issue = nil; firstTokenLatency = nil; avatar.event(.idle); saveHistory()
        if expanded { onResize?(true); focusRequest += 1 }
    }
    func setHistory(_ enabled: Bool) {
        historyEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "historyEnabled")
        saveHistory()
    }
    private func saveHistory() {
        let previous = persistence, snapshot = conversation, enabled = historyEnabled
        persistence = Task {
            await previous?.value
            do { if enabled { try await store.save(snapshot) } else { try await store.clear() } }
            catch { issue = "Could not update local history: " + error.localizedDescription }
        }
    }
    private func rebuildEntries() {
        entries = conversation.messages.compactMap { message in
            if message.role == "user" || message.role == "assistant" {
                return message.content.isEmpty ? nil : ChatEntry(role: message.role, text: message.content)
            }
            if message.role == "tool", let result = try? JSONDecoder().decode(ToolResult.self, from: Data(message.content.utf8)) {
                return ChatEntry(role: "tool", text: message.tool_name ?? "Tool", result: result)
            }
            return nil
        }
    }
    func savePerformanceReport() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Mewpon Performance.json"
        panel.begin{[weak self] response in
            guard response == .OK,let url=panel.url else{return}
            Task{@MainActor in
                do{let data=try await PerformanceProfiler.shared.reportJSON();try data.write(to:url,options:.atomic)}
                catch{self?.issue="Could not save performance metrics: "+error.localizedDescription}
            }
        }
    }
    var canOpenResults:Bool { !paused && (!busy || searchProgressID != nil) }
    func openResult(_ item: ResultItem) {
        guard canOpenResults else{return}
        let call:ToolCall
        if item.kind=="python-project-vscode" {call=ToolCall(name:"open_python_project",arguments:["path":.string(item.path)])}
        else if item.kind.hasPrefix("document-with:") {call=ToolCall(name:"open_selected_document_with",arguments:["path":.string(item.path),"application":.string(String(item.kind.dropFirst("document-with:".count)))])}
        else {call=ToolCall(name:item.kind=="application" ? "open_application":"open_path",arguments:[item.kind=="application" ? "application":"path":.string(item.path)])}
        if busy {
            let previous=generation
            cancel()
            Task {await previous?.value;guard !paused,!busy else{return};runDirect(call,userSelected:true)}
        } else {runDirect(call,userSelected:true)}
    }
    func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.runDirect(ToolCall(name: "open_path", arguments: ["path": .string(url.path)]),userSelected:true) }
        }
    }
    func runDirect(_ call: ToolCall,userSelected:Bool=false) {
        guard !paused, !busy else { return }
        busy = true; permissions.beginRequest(); requestFailed = false; startedAt = .now; avatar.event(.working)
        let id=UUID();activeRequest=id
        generation = Task {
            defer{if activeRequest==id{finishRequest()}}
            let result = await makeRouter(request:id).execute(call) { [weak self] capability, tool, arguments in
                guard let self else { return false }
                return await self.authorizeAction(capability, tool: tool, arguments: arguments)
            }
            requestFailed = !result.success
            entries.append(ChatEntry(role: "tool", text: call.function.name, result: result))
            conversation.append(ChatMessage(role: "user", content: "Explicit action: " + call.function.name))
            conversation.append(ChatMessage(role: "assistant", content: "Actual tool result (untrusted data): " + result.json))
            try? await store.log(tool: call.function.name, success: result.success)
            saveHistory()
            avatar.event(Task.isCancelled ? .idle : result.success ? .success : .failure, returnToIdle: true)
        }
    }
}
