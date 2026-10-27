import Foundation

/// Only exact deterministic user requests qualify. Model-selected actions never do.
public enum DirectActionPolicy {
    public static func permits(_ decision: RoutingDecision, capability: Capability, tool: String, arguments: [String: JSONValue]) -> Bool {
        let safe = (tool == "open_application" && capability == .launchApplication) ||
            (tool == "open_path" && capability == .openPath) ||
            (tool == "search_files" && capability == .searchFiles) ||
            (tool == "python_project" && capability == .openPath) ||
            (tool == "open_python_project" && capability == .openPath) ||
            (tool == "remember_file_alias" && capability == .searchFiles)
        guard safe else { return false }
        guard case .deterministic(let invocation) = decision else { return false }
        switch invocation {
        case .tool(let call): return call.function.name == tool && call.function.arguments == arguments
        case .rememberFileAlias(let alias):return capability == .searchFiles && tool == "remember_file_alias" && arguments["alias"] == .string(alias)
        case .searchAndOpen: return tool == "search_files" || tool == "open_path"
        default: return false
        }
    }
}
