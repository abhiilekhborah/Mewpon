import AppKit
import SwiftUI
import MewponCore

struct SavedRoutine: Codable, Identifiable, Equatable {
    var id = UUID(); var name: String; var commands: [String]
}
@MainActor final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()
    @Published private(set) var routines: [SavedRoutine]
    @Published var issue: String?
    private let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mewpon/Automation/routines.json")
        routines = (try? Data(contentsOf: self.url)).flatMap { try? JSONDecoder().decode([SavedRoutine].self, from: $0) } ?? []
    }
    static let allowedTools: Set<String> = ["open_application", "open_path", "output_volume", "audio_control", "system_settings", "mewpon_theme", "window_control", "system_info", "date_time", "calculator", "display_control", "wifi_status", "bluetooth_status", "open_document_with", "latest_python_project"]
    static func calls(_ commands: [String]) throws -> [ToolCall] {
        guard !commands.isEmpty, commands.count <= 8 else { throw MewponError.invalid("Save one to eight complete low-risk commands.") }
        var calls: [ToolCall] = []
        for command in commands {
            guard case .deterministic(let invocation) = FastIntentRouter.classify(command) else { throw MewponError.invalid("This routine step needs a complete supported native command: \(command)") }
            let steps: [ToolCall]
            switch invocation { case .tool(let call): steps = [call]; case .plan(let values): steps = values; default: throw MewponError.invalid("This workflow is not available in a low-risk routine.") }
            for call in steps {
                guard allowedTools.contains(call.function.name), call.function.arguments["action"]?.string != "close", call.function.arguments["action"]?.string != "preferences" else { throw MewponError.invalid("Routine contains an action requiring individual review.") }
                calls.append(call)
            }
        }
        guard calls.count <= 8 else { throw MewponError.invalid("Routine exceeds eight actions.") }
        return calls
    }
    func save(name: String, commands: [String]) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !name.contains("\n") else { throw MewponError.invalid("Use a routine name up to 60 characters.") }
        _ = try Self.calls(commands)
        var next = routines.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        guard next.count < 30 else { throw MewponError.invalid("Keep up to 30 saved routines.") }
        next.append(SavedRoutine(name: name, commands: commands)); try persist(next); routines = next
    }
    func remove(_ id: UUID) { do { let next = routines.filter { $0.id != id }; try persist(next); routines = next } catch { issue = error.localizedDescription } }
    private func persist(_ values: [SavedRoutine]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
struct SavedRoutineTool: AssistantTool {
    let run: @Sendable (String) async throws -> ToolResult
    let spec = ToolSpec("run_saved_routine", "Run an explicitly user-saved low-risk routine by exact name. Unknown names do not create or execute actions.", fields: ["name": "Exact saved routine name"], capability: .routine, timeout: 90)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult { try await run(arguments["name"]!.string!) }
}
struct RoutineSettings: View {
    @ObservedObject private var store = RoutineStore.shared
    @State private var name = "Studying"
    @State private var commands = "Volume 20\nOpen VS Code"
    var body: some View {
        Section("Saved trusted routines") {
            ForEach(store.routines) { routine in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(routine.name).font(.headline); Spacer(); Button("Remove") { store.remove(routine.id) } }
                    ForEach(Array(routine.commands.enumerated()), id: \.offset) { _, command in Text(command).font(.caption) }
                }
            }
            TextField("Routine name", text: $name)
            TextEditor(text: $commands).font(.system(.caption, design: .monospaced)).frame(height: 90)
            Button("Save reviewed routine") {
                do { try store.save(name: name, commands: commands.split(separator: "\n").map(String.init)); store.issue = nil }
                catch { store.issue = error.localizedDescription }
            }
            Text("One complete native command per line; up to eight actions. No shell, script, deletion, or overwrite steps. Each step still respects capability denials and macOS permissions.").font(.caption).foregroundStyle(.secondary)
            if let issue = store.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }
    }
}
