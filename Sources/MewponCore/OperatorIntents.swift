import Foundation

public enum OperatorIntents {
    public static func classify(_ input: String) -> RoutingDecision? {
        guard input.count <= 4000, !input.contains(";"), !input.contains("\n"), !CommandNormalizer.hasQuotes(input) else { return nil }
        var s = CommandNormalizer.normalize(input)
        let words = Set(s.split(separator: " ").map(String.init))
        guard words.isDisjoint(with: ["not", "never", "dont", "don't", "without", "unless", "if", "why"]), !s.contains("how to"), !s.hasPrefix("how ") else { return nil }
        for prefix in ["please ", "can you ", "could you "] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        func tool(_ name: String, _ arguments: [String: String] = [:]) -> RoutingDecision {
            .deterministic(.tool(.init(name: name, arguments: arguments.mapValues(JSONValue.string))))
        }
        if ["turn the volume down", "turn volume down", "volume down", "lower the volume", "decrease volume"].contains(s) { return tool("output_volume", ["level": "down"]) }
        if ["turn the volume up", "turn volume up", "volume up", "raise the volume", "increase volume"].contains(s) { return tool("output_volume", ["level": "up"]) }
        if ["voice settings", "open voice settings", "voice interaction"].contains(s) { return tool("assistant_workspace", ["workspace":"voice"]) }
        if ["meeting notes", "open meeting notes", "open meetings"].contains(s){return tool("assistant_workspace",["workspace":"meetings"])}
        if ["voice studio", "open voice studio"].contains(s) { return tool("assistant_workspace", ["workspace":"studio"]) }
        if ["stop listening", "stop microphone", "pause all recording"].contains(s){return tool("voice_output",["action":"stop_all","text":"none"])}
        if ["stop speaking", "stop talking", "stop voice"].contains(s) { return tool("voice_output", ["action":"stop", "text":"none"]) }
        if s.hasPrefix("read aloud ") { return tool("voice_output", ["action":"speak", "text":String(s.dropFirst(11))]) }
        for prefix in ["volume ", "volum ", "vol ", "set volume ", "set volume to "] where s.hasPrefix(prefix) {
            if let n = Int(s.dropFirst(prefix.count).replacingOccurrences(of: "%", with: "")), (0...100).contains(n) { return tool("output_volume", ["level": String(n)]) }
        }
        if ["mute", "mute my mac", "mute audio", "unmute", "unmute my mac"].contains(s) { return tool("audio_control", ["action": s.hasPrefix("unmute") ? "unmute" : "mute", "device": "default"]) }
        if ["audio devices", "output devices", "list audio devices"].contains(s) { return tool("audio_control", ["action": "list", "device": "default"]) }
        for prefix in ["switch audio to ", "switch output to "] where s.hasPrefix(prefix) { return tool("audio_control", ["action": "switch", "device": String(s.dropFirst(prefix.count))]) }
        if ["display info", "connected monitors", "screen resolutions", "brightness", "screen brightness"].contains(s) { return tool("display_control", ["action": "status", "value": "read"]) }
        for prefix in ["brightness ", "set brightness to "] where s.hasPrefix(prefix) { if let n = Int(s.dropFirst(prefix.count).replacingOccurrences(of: "%", with: "")), (0...100).contains(n) { return tool("display_control", ["action": "brightness", "value": String(n)]) } }
        if ["bluetooth status", "bluetooth"].contains(s) { return tool("bluetooth_status") }
        for pane in ["bluetooth", "battery", "network", "wallpaper", "appearance"] where s == "open "+pane+" settings" { return tool("system_settings", ["pane": pane]) }
        if s == "open system settings and show bluetooth" { return tool("system_settings", ["pane": "bluetooth"]) }
        // Exact imperative grammar: accept ordinary wording without sending
        // appearance changes through model inference. Do not match explanations,
        // negations, conditional requests, or clauses with additional actions.
        for mode in ["dark", "light"] {
            let targets = [mode + " mode", mode + " appearance", "macos " + mode + " mode", "system " + mode + " mode"]
            let verbs = ["", "enable ", "use ", "activate ", "turn on ", "switch to ", "change to ", "set to ", "change it to ", "switch it to ", "set it to ", "switch my mac to ", "change my mac to ", "set my mac to ", "switch macos to ", "change macos to ", "set macos to ", "switch the system to "]
            if targets.contains(where: { target in verbs.contains(where: { s == $0 + target }) }) {
                return tool("system_appearance", ["mode": mode])
            }
        }
        if ["sleep my mac", "sleep the mac", "put my mac to sleep"].contains(s) { return tool("power_control", ["action": "sleep"]) }
        if ["lock my mac", "lock screen", "lock the screen"].contains(s) { return tool("power_control", ["action": "lock"]) }
        if ["open my cv in preview", "open my resume in preview", "find my cv and open it in preview"].contains(s) { return tool("open_document_with", ["query": "resume cv", "application": "Preview"]) }
        if ["open my latest python project in vs code", "open my latest python project in vscode"].contains(s) { return tool("latest_python_project") }
        if ["move today's screenshots into a new folder", "organize today's screenshots", "organise today's screenshots"].contains(s) { return .deterministic(.organizeScreenshots) }
        if ["open my project and start the development server", "open my project and start dev server"].contains(s) { return .deterministic(.reviewedWorkflow(name: "development", openProject: true)) }
        if ["start my development server", "start dev server"].contains(s) { return .deterministic(.reviewedWorkflow(name: "development", openProject: false)) }
        if s.hasPrefix("run workflow ") { return .deterministic(.reviewedWorkflow(name: String(s.dropFirst(13)), openProject: false)) }
        if ["set my mac for studying", "study mode", "run study routine"].contains(s) { return tool("run_saved_routine", ["name": "Studying"]) }
        for prefix in ["run routine ", "run my routine "] where s.hasPrefix(prefix) { return tool("run_saved_routine", ["name": String(s.dropFirst(prefix.count))]) }
        for theme in ["liquid glass", "minimal light", "midnight", "arctic blue", "warm paper", "developer"] {
            if ["use the "+theme+" theme", "switch mewpon to "+theme, "change your theme to "+theme, "theme "+theme, "enable "+theme].contains(s) { return tool("mewpon_theme", ["theme": theme.replacingOccurrences(of: " ", with: "-")]) }
        }
        if s == "make mewpon minimal" { return tool("mewpon_theme", ["theme": "minimal-light"]) }
        func capture(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: s).map { String(s[$0]) } }
        }
        if let v = capture("^(?:put|arrange) (.+?) (?:on the left and|and) (.+?) (?:on the right|side by side)$"), v.count == 2 {
            return .deterministic(.plan([.init(name: "window_control", arguments: ["application": .string(v[0]), "action": .string("left")]), .init(name: "window_control", arguments: ["application": .string(v[1]), "action": .string("right")])]))
        }
        for action in ["center", "minimize", "restore", "close"] where s.hasPrefix(action+" ") {
            let app = String(s.dropFirst(action.count+1)).replacingOccurrences(of: " window", with: "")
            if !app.isEmpty, !app.contains(" and ") { return tool("window_control", ["application": app, "action": action]) }
        }
        for app in ["music", "spotify"] {
            for action in ["play", "pause", "next", "previous"] where s == action+" "+app || s == action+" track in "+app { return tool("media_control", ["application": app, "action": action]) }
        }
        if s.hasPrefix("open "), s.hasSuffix(" preferences") { return tool("window_control", ["application": String(s.dropFirst(5).dropLast(12)), "action": "preferences"]) }
        if s == "move this window to the other monitor" { return tool("window_control", ["application": "frontmost", "action": "next-monitor"]) }
        if s.hasPrefix("minimize everything except ") { return tool("minimize_other_windows", ["except": String(s.dropFirst(27))]) }
        // File operations preserve the spelling and case of absolute paths.
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: "^(copy|move|rename) (/[\\s\\S]+|~/[\\s\\S]+) to (/[\\s\\S]+|~/[\\s\\S]+)$", options: .caseInsensitive), let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            let values = (1...3).compactMap { Range(match.range(at: $0), in: raw).map { String(raw[$0]) } }
            if values.count == 3 { return tool("file_operation", ["operation": values[0].lowercased(), "source": values[1], "destination": values[2]]) }
        }
        if s.hasPrefix("create folder "), let range = raw.range(of: "create folder ", options: .caseInsensitive), range.lowerBound == raw.startIndex {
            let path = String(raw[range.upperBound...]); if path.hasPrefix("/") || path.hasPrefix("~/") { return tool("file_operation", ["operation": "mkdir", "source": "none", "destination": path]) }
        }
        // A bounded sequence of complete recognized actions; no free-form program.
        let parts = s.replacingOccurrences(of: " and then ", with: " and ").components(separatedBy: " and ")
        if (2...8).contains(parts.count) {
            var calls: [ToolCall] = []
            for part in parts {
                guard case .deterministic(.tool(let call)) = FastIntentRouter.classify(part), !["run_saved_routine", "power_control", "file_operation", "apply_file_batch"].contains(call.function.name) else { return nil }
                if calls.last != call { calls.append(call) }
            }
            return .deterministic(.plan(calls))
        }
        return nil
    }
}
