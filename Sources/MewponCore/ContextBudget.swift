import Foundation

public enum ContextBudget {
    /// Conservative estimate, not a tokenizer. Drop whole older turns so tool
    /// responses stay attached. Never silently truncate the latest request.
    public static func messages(_ messages:[ChatMessage],system:String,toolBytes:Int,configuration:ModelConfiguration) throws ->[ChatMessage] {
        let available=max(256,configuration.contextWindow-configuration.maximumTokens-256)
        func cost(_ values:[ChatMessage])->Int {
            let bytes=(try? JSONEncoder().encode(values).count) ?? values.reduce(0){$0+$1.content.utf8.count}
            return (bytes+system.utf8.count+toolBytes+2)/3
        }
        var result=messages
        while cost(result)>available {
            guard let next=result.dropFirst().firstIndex(where:{$0.role=="user"}) else {
                throw MewponError.invalid("This request and its tool results exceed the context budget. Increase context or start a new chat with a smaller request.")
            }
            result.removeFirst(next)
        }
        if result.count<messages.count{result.insert(ChatMessage(role:"system",content:"Older whole conversation turns were omitted to fit context. Do not invent missing details; ask when they matter."),at:0)}
        return result
    }
}
public enum ToolContextPolicy {
    public static func needsTools(_ prompt:String)->Bool {
        let s=CommandNormalizer.normalize(prompt)
        if CommandNormalizer.hasQuotes(prompt) || s.contains("how to ") || s.hasPrefix("how do ") || s.hasPrefix("how can ") || s.hasPrefix("why ") || s.hasPrefix("what does ") || s.contains("tell me how "){return false}
        let tokens=Set(s.split(separator:" ").map(String.init))
        if !tokens.isDisjoint(with:["not","never","don't","dont","without","unless","if"]) || prompt.contains("\"") || prompt.contains("“") || prompt.contains("”") || prompt.first=="'"{return false}
        // Explanations and code-writing never need native tool authority.
        if ["explain ","write ","describe ","how to ","how do ","can you tell me how ","don't ","do not ","never "].contains(where:s.hasPrefix){return false}
        // Conversation and general knowledge do not need desktop tool schemas.
        // Keep ambiguous action requests on the existing tool path.
        let actions: Set<String> = ["open", "launch", "start", "run", "find", "search", "locate", "show", "reveal", "preview", "read", "check", "inspect", "switch", "focus", "hide", "quit", "close", "set", "change", "turn", "mute", "unmute", "increase", "decrease", "calculate", "remember", "clipboard", "screen", "selected", "selection"]
        let measured: Set<String> = ["battery", "charging", "storage", "disk", "memory", "ram", "wifi", "wi-fi", "volume", "brightness", "time", "date", "downloads", "documents", "desktop", "file", "files", "folder", "folders", "settings", "running", "my", "our", "this", "these", "those", "here", "current", "now", "today", "tomorrow", "weather", "forecast", "rain", "temperature", "news", "headlines", "sports", "traffic", "remind", "calendar", "contacts", "translate", "translation", "convert"]
        if tokens.isDisjoint(with: actions), tokens.isDisjoint(with: measured) {
            if ["hi", "hello", "hey", "hi mewpon", "hello mewpon", "hey mewpon", "thanks", "thank you", "good morning", "good evening"].contains(s) { return false }
            if ["what ", "who ", "where ", "when ", "why ", "how ", "tell me ", "help me understand ", "can you explain ", "could you explain ", "summarize ", "translate ", "compare ", "define "].contains(where: s.hasPrefix) { return false }
        }
        return true
    }
}

/// Keep the model's tool descriptions within the selected local context. This
/// selects schemas only; the central executor still authorizes every action.
public enum ToolCatalog {
    public static func select(prompt: String, available: [ToolDefinition], configuration: ModelConfiguration) -> [ToolDefinition] {
        guard ToolContextPolicy.needsTools(prompt) else { return [] }
        let text = CommandNormalizer.normalize(prompt)
        let words = Set(text.split(separator: " ").map(String.init))
        var names: [String] = []
        func add(_ values: [String]) { for name in values where !names.contains(name) { names.append(name) } }
        if !words.isDisjoint(with: ["calculate", "calculator", "arithmetic"]) { add(["calculator"]) }
        if !words.isDisjoint(with: ["time", "date", "today"]) { add(["date_time"]) }
        if !words.isDisjoint(with:["remind","reminder","reminders","due"]){add(["local_reminders","productivity_due_week","assistant_workspace"])}
        if !words.isDisjoint(with:["calendar","schedule","meeting","event"]){add(["calendar_query","calendar_write","assistant_workspace"])}
        if !words.isDisjoint(with:["contact","contacts"]){add(["contact_query","assistant_workspace"])}
        if !words.isDisjoint(with:["translate","translation","hindi","english"]){add(["translate_text"])}
        if !words.isDisjoint(with:["convert","conversion","units","kilometers","miles","celsius"]){add(["unit_conversion","calculator"])}
        if !words.isDisjoint(with:["timezone","zone","time"]){add(["time_zone","date_time"])}
        if !words.isDisjoint(with:["weather","forecast","rain","temperature"]){add(["weather"])}
        if !words.isDisjoint(with:["news","headlines","sports"]){add(["online_news"])}
        if !words.isDisjoint(with:["web","website","url","https","browse"]){add(["open_url","read_context"])}
        if !words.isDisjoint(with:["voice","speak","speaking","aloud","studio"]){add(["voice_output","assistant_workspace"])}
        if !words.isDisjoint(with: ["dark", "light", "appearance", "theme", "midnight", "arctic", "glass", "paper", "minimal"]) { add(["system_appearance", "mewpon_theme", "system_settings"]) }
        if !words.isDisjoint(with: ["volume", "audio", "sound", "mute", "unmute", "headphones", "speaker", "speakers"]) { add(["output_volume", "audio_control", "system_settings"]) }
        if !words.isDisjoint(with: ["music", "spotify", "playback", "pause", "track"]) { add(["media_control", "open_application"]) }
        if !words.isDisjoint(with: ["window", "windows", "left", "right", "monitor", "minimize", "resize", "center", "restore"]) { add(["window_control", "minimize_other_windows", "open_application"]) }
        if !words.isDisjoint(with: ["bluetooth", "wifi", "wi-fi", "network", "brightness", "display", "battery", "charging", "memory", "storage"]) { add(["system_settings", "system_info", "wifi_status", "bluetooth_status", "display_control"]) }
        if !words.isDisjoint(with: ["routine", "studying", "study"]) { add(["run_saved_routine"]) }
        if !words.isDisjoint(with: ["workflow", "server", "development"]) { add(["prepare_workflow", "run_builtin_server", "run_approved_workflow", "open_workflow_project"]) }
        if !words.isDisjoint(with: ["copy", "move", "rename", "create", "screenshots"]) { add(["file_operation", "prepare_screenshot_move", "apply_file_batch"]) }
        if !words.isDisjoint(with: ["context", "clipboard", "selected", "selection", "screen", "read"]) { add(["read_context", "read_document", "read_screen_text"]) }
        if !words.isDisjoint(with: ["quit", "hide", "activate", "preferences"]) { add(["application_control", "window_control", "open_application"]) }
        if !words.isDisjoint(with: ["sleep", "lock"]) { add(["power_control"]) }
        if !words.isDisjoint(with: ["file", "files", "folder", "folders", "pdf", "cv", "resume", "document", "documents", "project", "python", "search", "find", "locate"]) { add(["search_files", "open_document_with", "open_path", "python_project", "latest_python_project", "open_python_project", "finder_action"]) }
        if !words.isDisjoint(with:["open","launch","activate","application","applications","app"]){add(["open_application"])}
        if names.isEmpty{add(["open_application", "search_files", "open_path", "system_settings", "system_info", "date_time", "calculator"])}
        // Small injected catalogs (including extensions) retain their existing
        // tools when capacity permits. The full desktop catalog is narrowed.
        if available.count <= 8 { add(available.map { $0.function.name }.sorted()) }
        let byName = Dictionary(uniqueKeysWithValues: available.map { ($0.function.name, $0) })
        // Reserve room for the system instruction, latest user message, JSON
        // overhead, and a native result. Never change the user's model/context.
        let contextBytes = max(0, configuration.contextWindow - configuration.maximumTokens - 256) * 3
        let budget = min(6000, max(0, contextBytes - AgentController.systemPrompt.utf8.count - prompt.utf8.count - 1200))
        var result: [ToolDefinition] = []
        for name in names {
            guard let tool = byName[name], result.count < 8 else { continue }
            let candidate = result + [tool]
            if let data = try? JSONEncoder().encode(candidate), data.count <= budget { result = candidate }
        }
        return result
    }
}
