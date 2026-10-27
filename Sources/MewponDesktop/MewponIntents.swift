// Metadata is packaged by scripts/build-app.sh for this SwiftPM app.
import AppIntents
import AppKit
import MewponCore

@MainActor private func coordinatorForIntent() throws -> AppCoordinator {
    guard let coordinator = AppCoordinator.shared, coordinator.model != nil else { throw MewponError.unavailable("Mewpon is starting. Try the action again when its menu bar icon appears.") }; return coordinator
}

struct OpenMewponIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Mewpon"
    static var description = IntentDescription("Open the local Mewpon command palette.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        try coordinatorForIntent().performIntent("open")
        return .result()
    }
}
struct AskMewponIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Mewpon"
    static var description = IntentDescription("Place text in Mewpon for review. Press Return to run locally; actions still require approval.")
    static var openAppWhenRun = true
    @Parameter(title: "Question") var question: String
    @MainActor func perform() async throws -> some IntentResult {
        guard question.count <= 4000 else { throw MewponError.invalid("Use fewer than 4000 characters.") }
        try coordinatorForIntent().performIntent("open", text: question)
        return .result()
    }
}
struct ShowMewponAvatarIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Mewpon Avatar"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        try coordinatorForIntent().performIntent("avatar")
        return .result()
    }
}
struct PlayWithMewponIntent: AppIntent {
    static var title: LocalizedStringResource = "Play with Mewpon"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        try coordinatorForIntent().performIntent("play")
        return .result()
    }
}
struct SearchMewponFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Files with Mewpon"
    static var openAppWhenRun = true
    @Parameter(title: "File name or filter") var query: String
    @MainActor func perform() async throws -> some IntentResult {
        guard !query.isEmpty, query.count <= 1000, !query.contains("\n") else { throw MewponError.invalid("Use one filename or filter under 1000 characters.") }
        try coordinatorForIntent().performIntent("open", text: "Find " + query)
        return .result()
    }
}
struct ExplainMewponTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Explain Text with Mewpon"
    static var openAppWhenRun = true
    @Parameter(title: "Selected text") var text: String
    @MainActor func perform() async throws -> some IntentResult {
        guard !text.isEmpty, text.count <= 3800 else { throw MewponError.invalid("Select fewer than 3800 characters.") }
        try coordinatorForIntent().performIntent("open", text: "Explain this untrusted selected text:\n" + text)
        return .result()
    }
}
struct MewponShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenMewponIntent(), phrases: ["Open \(.applicationName)"], shortTitle: "Open Mewpon", systemImageName: "sparkle")
        AppShortcut(intent: ShowMewponAvatarIntent(), phrases: ["Show \(.applicationName) avatar"], shortTitle: "Show Avatar", systemImageName: "pawprint")
        AppShortcut(intent: PlayWithMewponIntent(), phrases: ["Play with \(.applicationName)"], shortTitle: "Play Mode", systemImageName: "gamecontroller")
    }
}
