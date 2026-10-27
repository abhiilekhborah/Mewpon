import AppKit
import MewponCore

/// Only the separately packaged review bundle can load controlled visual fixtures.
/// The production bundle never enters this mode or writes review artifacts.
@MainActor enum UIReview {
    static var enabled: Bool { Bundle.main.bundleIdentifier == "local.mewpon.uireview" }
    static let states = ["Idle", "Suggestions", "Files", "Executing", "Answer", "Markdown", "Light", "Dark", "Settings", "Local chat", "Save metrics"]
    private static var directory: URL?
    static func populate(_ model: AssistantModel, state: String) throws {
        model.cancel(); model.busy = false; model.issue = nil; model.input = ""; model.entries = []; model.droppedText = nil
        model.ready = true
        if state == "Suggestions" { model.input = "Open"; return }
        if state == "Executing" { model.busy = true; model.status = "Opening Safari…"; return }
        if state == "Files" {
            if directory == nil {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-UI-Review-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); directory = root
            }
            let root = directory!
            let fixture = Bundle.main.resourceURL!.appendingPathComponent("review-fixture.pdf")
            let names = ["Project brief.pdf", "Design notes.md", "Meeting summary.pdf", "Release checklist.md", "Research notes.pdf", "Planning notes.md", "Review draft.pdf", "Outline.md"]
            let items = try names.map { name -> ResultItem in
                let url = root.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    if url.pathExtension == "pdf" { try FileManager.default.copyItem(at: fixture, to: url) }
                    else { try "# Mewpon UI review\n\nControlled local fixture.\n".write(to: url, atomically: true, encoding: .utf8) }
                }
                return ResultItem(name: name, path: url.path, kind: url.pathExtension)
            }
            var result = ToolResult(true, "Found 8 indexed files.", items: items); result.partial = true
            model.entries = [ChatEntry(role: "user", text: "Find my project files"), ChatEntry(role: "tool", text: result.summary, result: result), ChatEntry(role: "assistant", text: result.summary)]
        } else if state == "Answer" || state == "Light" || state == "Dark" {
            model.entries = [ChatEntry(role: "user", text: "How can I plan a focused morning?"), ChatEntry(role: "assistant", text: "Start with one clear outcome. Choose the most important task, silence avoidable interruptions, and work in a short block before taking a break.\n\n- Pick a task you can describe in one sentence.\n- Keep only the tools you need open.\n- Leave a quick note about your next step.")]
        } else if state == "Markdown" {
            model.entries = [ChatEntry(role: "user", text: "Show a structured Swift example"), ChatEntry(role: "assistant", text: markdown)]
        }
    }
    static let markdown = """
    ## A small, predictable workflow

    Use **clear inputs** and a single source of truth. Keep the interface responsive while work runs in the background.

    ### Example

    ```swift
    struct TaskSummary {
        let title: String
        let completed: Bool
    }

    func describe(_ task: TaskSummary) -> String {
        if task.completed {
            return "Finished: " + task.title
        }
        return "In progress: " + task.title
    }
    ```

    ### Review checklist

    1. Keep the composer available during a response.
    2. Preserve the user's scroll position.
    3. Use `Task.checkCancellation()` before starting another action.

    | State | Feedback |
    | --- | --- |
    | Ready | Compact command bar |
    | Working | Inline progress |
    | Finished | Verified result |

    > A tool result is data, not a new instruction.

    Read the [Swift documentation](https://www.swift.org/documentation/) for more details.

    ### Additional notes

    Longer answers scroll within the same bounded panel. Text remains selectable, code scrolls horizontally, and the window never grows to fill the display.

    The mascot continues using its existing rendering engine. Showing an answer does not create or reload a WebView.
    """
    static func exportMetrics() async throws {
        guard enabled, let path = Bundle.main.object(forInfoDictionaryKey: "MewponReviewOutput") as? String else { return }
        let data = try await PerformanceProfiler.shared.reportJSON()
        try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("runtime-metrics.json"), options: .atomic)
    }
    static func cleanup() { if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil }
}
