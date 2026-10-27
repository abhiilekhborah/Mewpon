import Foundation

public enum ToolInvocation:Equatable,Sendable {
    case tool(ToolCall)
    case plan([ToolCall])
    case organizeScreenshots
    case reviewedWorkflow(name: String, openProject: Bool)
    case searchAndOpen(query:String)
    case explainContext(kind: String)
    case contextFolder
    case rememberFileAlias(alias:String)
}
public enum RoutingDecision:Equatable,Sendable {
    case deterministic(ToolInvocation)
    case needsClarification(String)
    case requiresLLM
}

public enum CommandNormalizer {
    public static func hasQuotes(_ input:String)->Bool {
        let s=input.replacingOccurrences(of:"‘",with:"'").replacingOccurrences(of:"’",with:"'")
        return s.filter{$0=="'"}.count>=2 || s.contains("\"") || s.contains("“") || s.contains("”") || s.first=="'" || s.last=="'"
    }
    public static func normalize(_ text:String)->String {
        text.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of:"’",with:"'").replacingOccurrences(of:"‘",with:"'")
            .split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").trimmingCharacters(in:CharacterSet(charactersIn:" .!?"))
    }
}

/// Conservative token grammar: only explicit complete commands enter the fast
/// path. Unknown arguments remain literal; fuzzy matching never picks a file/app.
public actor FastIntentRouter {
    private let cache=BoundedCache<String,RoutingDecision>(capacity:256,ttl:.seconds(300))
    public init(){}
    public func route(_ input:String)->RoutingDecision {
        Self.classify(input)
    }
    public func cachedRoute(_ input:String) async -> RoutingDecision {
        let start=ContinuousClock.now,key=input.contains("/") ? input:CommandNormalizer.normalize(input)
        if let translation=InformationIntents.translation(input){return translation}
        // Quoted instructions must never borrow an unquoted cached decision.
        guard input.count<=4000,!CommandNormalizer.hasQuotes(input),!input.contains("\n"),!input.contains(";") else{return .requiresLLM}
        let decision:RoutingDecision
        if let hit=await cache.value(for:key){decision=hit}else{decision=Self.classify(input);if case .deterministic=decision{await cache.insert(decision,for:key)}}
        await PerformanceProfiler.shared.record("intent.classification",since:start);return decision
    }

    public static func classify(_ input:String)->RoutingDecision {
        if let translation=InformationIntents.translation(input){return translation}
        guard input.count<=4000,!CommandNormalizer.hasQuotes(input),!input.contains("\n"),!input.contains(";") else{return .requiresLLM}
        if let local=LocalInformation.classify(input){return local}
        if let information=InformationIntents.classify(input){return information}
        if let productivity = ProductivityIntents.classify(input){return productivity}
        if let operatorPlan = OperatorIntents.classify(input) { return operatorPlan }
        var s=CommandNormalizer.normalize(input)
        let words=s.split(separator:" ").map(String.init)
        let blocked:Set<String>=["not","never","don't","dont","cannot","can't","without","unless","if","then","instead","previous","last-used"]
        guard blocked.isDisjoint(with:words),!s.contains("how to"),!s.hasPrefix("how do "),!s.contains(" how do "),!s.contains("tell me how"),!s.hasPrefix("how can "),!s.hasPrefix("why "),!s.hasPrefix("what does ") else{return .requiresLLM}
        for prefix in ["please ","can you ","could you ","would you "]{if s.hasPrefix(prefix){s=String(s.dropFirst(prefix.count))}}
        if s.hasPrefix("please "){s=String(s.dropFirst(7))}
        if s.hasSuffix(" please"){s=String(s.dropLast(7))}
        s = CommandVocabulary.command(s)
        func tool(_ name:String,_ args:[String:JSONValue]=[:])->RoutingDecision{.deterministic(.tool(ToolCall(name:name,arguments:args)))}
        if ["this is my cv","this is my resume"].contains(s){return .deterministic(.rememberFileAlias(alias:"resume cv curriculum vitae"))}
        if CommandVocabulary.isPythonProject(s){return tool("python_project",["editor":.string("search")])}
        let bare=CommandVocabulary.searchTokens(s)
        if !bare.isEmpty,bare.count<=6,!s.contains("/"),!s.contains("."),bare.allSatisfy({["resume","internship","report","pdf","presentations","yesterday","college","python","project"].contains($0)}) {
            return tool("search_files",["query":.string(s)])
        }
        if ["wifi status", "wi-fi status", "what's my wifi status"].contains(s) { return tool("wifi_status") }
        if ["volume", "output volume", "what's my volume"].contains(s) { return tool("output_volume", ["level": .string("read")]) }
        if s.hasPrefix("set volume to "), let n = Int(s.dropFirst(14).replacingOccurrences(of: "%", with: "")), (0...100).contains(n) { return tool("output_volume", ["level": .string(String(n))]) }
        for (prefix, action) in [("switch to ", "switch"), ("hide ", "hide"), ("quit ", "quit")] where s.hasPrefix(prefix) {
            let app = String(s.dropFirst(prefix.count))
            if !app.isEmpty, !app.contains(" and "), !app.contains(" or "), !app.contains(" because "), !app.contains(" when "), !app.contains(" to "), !app.contains("/"), app.split(separator: " ").count <= 6 { return tool("application_control", ["application": .string(app), "action": .string(action)]) }
        }
        for pane in ["sound", "display", "focus", "wifi", "keyboard", "privacy", "lock"] where s == "open " + pane + " settings" { return tool("system_settings", ["pane": .string(pane)]) }
        if ["explain this selected code", "explain selected text", "explain this selected text", "summarize this text", "what does this error mean"].contains(s) { return .deterministic(.explainContext(kind: "selectedText")) }
        if ["help me understand what's on my screen", "explain my screen", "read screen text"].contains(s) { return .deterministic(.explainContext(kind: "screen")) }
        if ["read browser page", "what page am i on"].contains(s) { return tool("read_context", ["kind": .string("browserPage")]) }
        if ["summarize my clipboard", "explain my clipboard"].contains(s) { return .deterministic(.explainContext(kind: "clipboard")) }
        if ["find the file i currently have selected", "show finder selection"].contains(s) { return tool("read_context", ["kind": .string("finderSelection")]) }
        if s == "open the folder containing this document" { return .deterministic(.contextFolder) }
        if ["lock screen", "lock my mac", "lock the screen"].contains(s) { return .needsClarification("Screen locking is not automated in this build. Use Control–Command–Q on your Mac, or ask to open lock settings.") }
        if ["turn on focus", "turn off focus", "toggle focus", "turn on do not disturb", "turn off do not disturb"].contains(s) { return .needsClarification("Focus switching is not available through the implemented public interfaces. Ask to open focus settings; no setting has been changed.") }
        if ["play media", "pause media", "next track", "previous track"].contains(s) { return .needsClarification("System-wide media control is not implemented. Use your media app's controls. No playback state was changed.") }
        if s == "screen brightness" || s == "what's my screen brightness" || s.hasPrefix("set brightness to ") { return .needsClarification("This display does not have an implemented public brightness control. Ask to open display settings; brightness has not been changed.") }
        let time:Set<String>=["what time is it","what's the time","what is the time","current time","time","today's date","what is today's date","what's today's date","date and time"]
        if time.contains(s){return tool("date_time")}
        let system:Set<String>=["battery","battery status","what's my battery","what is my battery","what's my battery percentage","what is my battery percentage","how much battery do i have","how much storage is left","how much storage do i have","storage available","memory usage","system info","device details","how much memory is free"]
        if system.contains(s){return tool("system_info")}
        for prefix in ["calculate ","compute ","what is "] where s.hasPrefix(prefix){
            let raw=String(s.dropFirst(prefix.count)).replacingOccurrences(of:"×",with:"*").replacingOccurrences(of:"÷",with:"/")
            if !raw.isEmpty,raw.allSatisfy({$0.isNumber||" .+-*/%^()".contains($0)}),raw.contains(where:{$0.isNumber}){
                return tool("calculator",["expression":.string(raw)])
            }
        }
        if ["open","launch","find","search","show"].contains(s){return .needsClarification("What would you like me to \(s)?")}
        var tokens=s.split(separator:" ").map(String.init)
        guard let first=tokens.first else{return .requiresLLM}
        let typoVerbs=["opne":"open","opn":"open","lauch":"launch","lanuch":"launch","fnd":"find"]
        tokens[0]=typoVerbs[first] ?? first
        var verb=tokens.removeFirst(),argument=tokens.joined(separator:" ")
        if verb=="where",argument.hasPrefix("is "){verb="find";argument=String(argument.dropFirst(3))}
        if verb=="search",argument.hasPrefix("for "){argument=String(argument.dropFirst(4))}
        for prefix in ["my ","the "]{if argument.hasPrefix(prefix){argument=String(argument.dropFirst(prefix.count))}}
        guard !argument.isEmpty,argument.count<=1024 else{return .requiresLLM}
        if ["it","that","this","them","file","app","application","file i was editing","something"].contains(argument){return .needsClarification("Please give the exact application, folder, or file name.")}
        if verb=="find",argument.hasSuffix(" and open it"){
            let query=String(argument.dropLast(12));guard safeSearch(query) else{return .requiresLLM}
            return .deterministic(.searchAndOpen(query:query))
        }
        if ["find","search"].contains(verb),argument.contains(" with "),!argument.contains(" and open"),!argument.contains(" and delete"),!argument.contains(" and launch"),!argument.contains(" and quit") {
            return tool("search_files",["query":.string(argument)])
        }
        guard !argument.contains(" and "),!argument.contains(" or "),!argument.contains(" because "),!argument.contains(" when "),!argument.contains(" to ") else{return .requiresLLM}
        if ["find","search"].contains(verb), CommandVocabulary.isPythonProject(argument) {
            return tool("python_project",["editor":.string("search")])
        }
        if ["find","search"].contains(verb){guard safeSearch(argument) else{return .requiresLLM};return tool("search_files",["query":.string(argument)])}
        if ["open","launch"].contains(verb), argument.hasPrefix("/") || argument.hasPrefix("~/") {
            // Preserve the exact spelling and case supplied by the user.
            let raw=input.trimmingCharacters(in:.whitespacesAndNewlines)
            if let start=raw.firstIndex(of:"/") {
                let pathStart=start>raw.startIndex && raw[raw.index(before:start)]=="~" ? raw.index(before:start):start
                return tool("open_path",["path":.string(String(raw[pathStart...]))])
            }
        }
        if ["open","show","find","search"].contains(verb), CommandVocabulary.isPythonProject(argument) {
            return tool("python_project",["editor":.string(argument.contains(" in ") ? "vscode":"default")])
        }
        if ["open","show"].contains(verb), ["cv","resume","my cv","my resume"].contains(argument) {
            return .deterministic(.searchAndOpen(query:argument))
        }
        let folders:Set<String>=["downloads","documents","desktop","home"]
        if ["open","show"].contains(verb),folders.contains(argument){return tool("open_path",["path":.string(argument)])}
        if verb=="show",argument=="recent presentations" || verb=="show" && (argument.hasPrefix("screenshots ") || argument.hasPrefix("everything named ")){return tool("search_files",["query":.string(argument)])}
        if ["open","launch","start"].contains(verb){
            guard argument.split(separator:" ").count<=6,!argument.contains("/"),!argument.contains("\\"),!argument.contains("?"),!argument.contains("!"),!argument.hasPrefix("file "),!argument.contains("i was ") else{return .requiresLLM}
            if argument.contains(".") && !argument.hasPrefix("com.") {return .requiresLLM}
            return tool("open_application",["application":.string(argument)])
        }
        return .requiresLLM
    }
    private static func safeSearch(_ s:String)->Bool {
        !s.isEmpty && s.count<=1024 && !s.contains("/") && !s.contains("\\") && !s.contains(" and ") && !s.contains("i was") && !s.contains("you ")
    }
}
