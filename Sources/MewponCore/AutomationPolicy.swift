import Foundation

public enum AutomationFeature: String, Codable, CaseIterable, Sendable {
    case applications, documents, audio, appearance, windows, fileChanges, quitApplications, routines, context, power, scripts, reminders, calendarRead, calendarWrite, contacts, network, communication
    public var title: String {
        switch self {
        case .reminders: return "Encrypted local reminders"
        case .calendarRead: return "Read authorized calendars"
        case .calendarWrite: return "Create and change calendar events"
        case .contacts: return "Search authorized contacts"
        case .network: return "Explicit online sources and browser navigation"
        case .communication: return "External communications · always review"
        case .scripts: return "Registered workflows · always review code execution"
        case .applications: return "Open and activate applications"
        case .documents: return "Search, open, and reveal files"
        case .audio: return "Audio volume, mute, and output device"
        case .appearance: return "Mewpon themes and macOS appearance"
        case .windows: return "Window arrangement and controls"
        case .fileChanges: return "Create, copy, move, and rename files"
        case .quitApplications: return "Request normal application quit"
        case .routines: return "Saved low-risk routines"
        case .context: return "Read document, clipboard, or screen context"
        case .power: return "Sleep and power actions"
        }
    }
}
public enum TrustRule: String, Codable, CaseIterable, Sendable { case ask, allow, scoped, deny }
public enum TrustVerdict: Equatable, Sendable { case allow, ask, deny }
public struct AutomationTrustPolicy: Codable, Sendable {
    public var enabled = true
    public var rules: [String: TrustRule] = [:]
    public var folders: [String] = []
    public var applications: [String] = []
    public init() {}
    public func rule(_ feature: AutomationFeature) -> TrustRule {
        if feature == .network{return rules[feature.rawValue] ?? .deny}
        return rules[feature.rawValue] ?? ([.applications, .documents, .audio, .appearance, .routines, .reminders, .calendarRead].contains(feature) ? .allow : .ask)
    }
    public static func feature(tool: String, arguments: [String: JSONValue]) -> AutomationFeature? {
        switch tool {
        case "local_reminders", "productivity_due_week":return .reminders
        case "calendar_query":return .calendarRead
        case "calendar_write":return .calendarWrite
        case "contact_query":return .contacts
        case "open_url", "weather", "online_news":return .network
        case "prepare_email":return .communication
        case "open_application", "assistant_workspace": return .applications
        case "application_control": return arguments["action"]?.string == "quit" ? .quitApplications : .applications
        case "search_files", "open_path", "finder_action", "python_project", "open_python_project", "remember_file_alias", "open_document_with", "open_selected_document_with", "latest_python_project", "prepare_screenshot_move": return .documents
        case "output_volume", "audio_control", "media_control", "voice_output": return .audio
        case "mewpon_theme", "system_appearance", "system_settings": return .appearance
        case "minimize_other_windows": return .windows
        case "window_control": return arguments["action"]?.string == "close" ? .quitApplications : .windows
        case "file_operation", "apply_file_batch": return .fileChanges
        case "run_saved_routine", "prepare_workflow", "run_builtin_server": return .routines
        case "run_approved_workflow": return .scripts
        case "open_workflow_project": return .documents
        case "read_context", "read_document", "read_screen_text": return .context
        case "power_control": return .power
        default: return nil
        }
    }
    public func evaluate(tool: String, arguments: [String: JSONValue]) -> TrustVerdict {
        guard enabled else { return .deny }
        guard let feature = Self.feature(tool: tool, arguments: arguments) else { return .ask }
        // This release exposes no destructive, credential, privileged, or arbitrary-code tool.
        if feature == .context || feature == .scripts || feature == .communication { return rule(feature) == .deny ? .deny : .ask }
        switch rule(feature) {
        case .allow: return .allow
        case .ask: return .ask
        case .deny: return .deny
        case .scoped:
            if feature == .applications || feature == .quitApplications || feature == .windows {
                return applications.contains { $0.caseInsensitiveCompare(arguments["application"]?.string ?? "") == .orderedSame } ? .allow : .ask
            }
            let paths = ["source", "destination", "path"].compactMap { arguments[$0]?.string }
            guard !paths.isEmpty, paths.allSatisfy({ path in
                let canonical = LocalPath.canonicalDestination(path)
                return folders.contains { root in canonical == LocalPath.canonical(root) || canonical.hasPrefix(LocalPath.canonical(root) + "/") }
            }) else { return .ask }
            return .allow
        }
    }
}
