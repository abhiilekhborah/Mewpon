import Foundation

/// Every fast-path step uses the same schema, authorization, deadline and result
/// boundary as an LLM tool call. Search and open remain sequential approvals.
public struct HybridAgentController:Sendable {
    let model:any LocalModelService;let router:ToolRouter
    public init(model:any LocalModelService,router:ToolRouter){self.model=model;self.router=router}
    public func respond(decision:RoutingDecision,history:[ChatMessage],configuration:ModelConfiguration,
                        onText:@escaping @Sendable(String) async ->Void,
                        onEvent:@escaping @Sendable(AssistantEvent) async ->Void,
                        authorize:@escaping @Sendable(Capability,String,[String:JSONValue]) async ->Bool,
                        onResult:@escaping @Sendable(String,ToolResult) async ->Void) async throws ->[ChatMessage] {
        switch decision {
        case .requiresLLM:
            return try await AgentController(model:model,router:router).respond(history:history,configuration:configuration,onText:onText,onEvent:onEvent,authorize:authorize,onResult:onResult)
        case .needsClarification(let question):await onText(question);return [ChatMessage(role:"assistant",content:question)]
        case .deterministic(let invocation):
            var produced:[ChatMessage]=[]
            func execute(_ call:ToolCall) async throws ->ToolResult {
                try Task.checkCancellation()
                await onEvent(call.function.name=="search_files" ? .searching:.working)
                let result=await router.execute(call,authorize:authorize)
                await onResult(call.function.name,result)
                produced.append(ChatMessage(role:"assistant",content:"",toolCalls:[call]))
                produced.append(ChatMessage(role:"tool",content:result.json,toolName:call.function.name))
                try Task.checkCancellation();return result
            }
            let result:ToolResult
            switch invocation {
            case .tool(let call):result=try await execute(call)
            case .plan(let calls):
                guard !calls.isEmpty, calls.count <= 8 else { throw MewponError.invalid("Use a plan with one to eight actions.") }
                var summaries: [String] = []
                var last = ToolResult(true, "")
                for call in calls {
                    last = try await execute(call); summaries.append(last.summary)
                    if !last.success { break }
                }
                result = ToolResult(last.success, summaries.joined(separator: "\n"), items: last.items)
            case .reviewedWorkflow(let name, let openProject):
                let preview = try await execute(ToolCall(name: "prepare_workflow", arguments: ["name": .string(name)]))
                if !preview.success { result = preview }
                else if let item = preview.items.first, item.kind.hasPrefix("workflow-plan:") || item.kind.hasPrefix("safe-workflow-plan:") {
                    let opened = openProject ? try await execute(ToolCall(name: "open_workflow_project", arguments: ["path": .string(item.path)])) : ToolResult(true, "")
                    if !opened.success { result = opened }
                    else {
                        let safe=item.kind.hasPrefix("safe-workflow-plan:")
                        let prefix=safe ? "safe-workflow-plan:":"workflow-plan:"
                        result = try await execute(ToolCall(name: safe ? "run_builtin_server":"run_approved_workflow", arguments: ["plan": .string(String(item.kind.dropFirst(prefix.count))), "preview": .string(preview.summary)]))
                    }
                } else { result = ToolResult(false, "No complete workflow preview was created. Nothing ran.") }
            case .organizeScreenshots:
                let preview = try await execute(ToolCall(name: "prepare_screenshot_move", arguments: [:]))
                if !preview.success { result = preview }
                else if let encoded = preview.items.first?.kind, encoded.hasPrefix("move-plan:") {
                    result = try await execute(ToolCall(name: "apply_file_batch", arguments: ["plan": .string(String(encoded.dropFirst(10))), "preview": .string(preview.summary)]))
                } else { result = ToolResult(false, "No complete move preview was created. Nothing was moved.") }
            case .explainContext(let kind):
                let context = try await execute(kind == "screen" ? ToolCall(name: "read_screen_text", arguments: [:]) : ToolCall(name: "read_context", arguments: ["kind": .string(kind)]))
                if !context.success { result = context }
                else {
                    let response = try await AgentController(model: model, router: ToolRouter(tools: [])).respond(history: history + produced, configuration: configuration, onText: onText, onEvent: onEvent, authorize: authorize, onResult: onResult)
                    return produced + response
                }
            case .rememberFileAlias(let alias):
                let previous=Array(history.dropLast())
                let turn=Array(previous.suffix(from:previous.lastIndex(where:{$0.role=="user"}) ?? previous.startIndex))
                if let message=turn.last(where:{$0.role=="tool" && $0.tool_name=="search_files"}),
                   let found=try? JSONDecoder().decode(ToolResult.self,from:Data(message.content.utf8)),found.success,found.items.count==1 {
                    result=try await execute(ToolCall(name:"remember_file_alias",arguments:["path":.string(found.items[0].path),"alias":.string(alias)]))
                } else {result=ToolResult(false,"Choose the file's menu → Remember as my CV, so I know which file you mean.")}
            case .contextFolder:
                let context = try await execute(ToolCall(name: "read_context", arguments: ["kind": .string("window")]))
                if context.success, context.items.count == 1 {
                    let folder = URL(fileURLWithPath: context.items[0].path).deletingLastPathComponent().path
                    result = try await execute(ToolCall(name: "open_path", arguments: ["path": .string(folder)]))
                } else { result = ToolResult(false, "No unique document URL was exposed. Choose or drop the file instead.") }
            case .searchAndOpen(let query):
                let found=try await execute(ToolCall(name:"search_files",arguments:["query":.string(query)]))
                if !found.success{result=found}
                else if found.items.count != 1 || found.partial == true {
                    result=ToolResult(false,found.items.isEmpty ? "No matching file was found. Nothing was opened.":"Choose the exact file from the search results. Nothing was opened automatically.",items:found.items)
                } else {result=try await execute(ToolCall(name:"open_path",arguments:["path":.string(found.items[0].path)]))}
            }
            await onText(result.summary)
            await onEvent(result.success ? .success:.failure)
            produced.append(ChatMessage(role:"assistant",content:result.summary));return produced
        }
    }
}
