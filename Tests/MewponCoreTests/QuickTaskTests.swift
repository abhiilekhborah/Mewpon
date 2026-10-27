import XCTest
import AppKit
@testable import MewponCore
@testable import MewponDesktop

final class QuickTaskTests: XCTestCase {
    func testSequenceTriggersOnceOnlyOnCommandAfterMew() {
        var recognizer = MewSequenceRecognizer()
        for (i, letter) in ["m", "e", "w"].enumerated() { recognizer.letter(letter, modified: false, repeated: false, time: Double(i) * 0.1) }
        XCTAssertFalse(recognizer.command(down: false, otherModifiers: false, time: 0.3))
        XCTAssertTrue(recognizer.command(down: true, otherModifiers: false, time: 0.4))
        XCTAssertFalse(recognizer.command(down: true, otherModifiers: false, time: 0.5))
        XCTAssertFalse(recognizer.command(down: false, otherModifiers: false, time: 0.6))
        XCTAssertFalse(recognizer.command(down: true, otherModifiers: false, time: 0.7))
    }
    func testSequenceRejectsTimeoutEditsModifiedKeysAndRepeats() {
        for invalid in ["timeout", "edit", "modified", "repeat", "other-modifier"] {
            var recognizer = MewSequenceRecognizer()
            recognizer.letter("m", modified: false, repeated: false, time: 0)
            recognizer.letter("e", modified: invalid == "modified", repeated: invalid == "repeat", time: 0.1)
            if invalid == "edit" { recognizer.letter(nil, modified: false, repeated: false, time: 0.15) }
            recognizer.letter("w", modified: false, repeated: false, time: 0.2)
            XCTAssertFalse(recognizer.command(down: true, otherModifiers: invalid == "other-modifier", time: invalid == "timeout" ? 3 : 0.3), invalid)
        }
    }
    // Local CGEvent objects exercise the callback; nothing is posted to macOS.
    @MainActor private func typeSequence(into shortcut: MewSequenceShortcut) {
        for key: CGKeyCode in [46, 14, 13] { // m, e, w on the test keyboard layout
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
            event.flags = []
            shortcut.receive(.keyDown, event)
        }
        let command = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true)!
        command.flags = .maskCommand
        shortcut.receive(.flagsChanged, command)
        command.flags = []
        shortcut.receive(.flagsChanged, command)
    }
    @MainActor func testListenerDefersWindowWorkAndCanHideThenShowAgain() async {
        _ = NSApplication.shared
        let shortcut = MewSequenceShortcut()
        let visibility = WindowVisibilityCoordinator(initial: .assistant)
        shortcut.toggle = { visibility.send(.toggle) }
        typeSequence(into: shortcut)
        XCTAssertEqual(visibility.effective, .assistant, "Window work must not run inside the event tap")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in visibility.effective == .hidden }, object: nil)
        await fulfillment(of: [hidden], timeout: 2)
        shortcut.reset() // Losing foreground focus must not disconnect the listener.
        typeSequence(into: shortcut)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in visibility.effective == .assistant }, object: nil)
        await fulfillment(of: [shown], timeout: 2)
        shortcut.shutdown()
    }
    @MainActor func testShutdownCancelsQueuedShortcutAndPartialLaunchCanTerminateSafely() async {
        _ = NSApplication.shared
        let shortcut = MewSequenceShortcut()
        var fired = false
        shortcut.toggle = { fired = true }
        typeSequence(into: shortcut)
        shortcut.shutdown()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertFalse(fired)
        let coordinator = AppCoordinator()
        XCTAssertFalse(coordinator.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        coordinator.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }
    func testDirectActionPolicyRequiresExactNativeRequestAndKeepsSensitiveApprovals() {
        let call = ToolCall(name: "open_application", arguments: ["application": .string("Safari")])
        let native = RoutingDecision.deterministic(.tool(call))
        XCTAssertTrue(DirectActionPolicy.permits(native, capability: .launchApplication, tool: "open_application", arguments: call.function.arguments))
        XCTAssertFalse(DirectActionPolicy.permits(native, capability: .launchApplication, tool: "open_application", arguments: ["application": .string("Terminal")]))
        XCTAssertFalse(DirectActionPolicy.permits(.requiresLLM, capability: .launchApplication, tool: "open_application", arguments: call.function.arguments))
        for tool in ["read_context", "read_document", "read_screen_text", "application_control", "set_volume"] {
            XCTAssertFalse(DirectActionPolicy.permits(.deterministic(.tool(ToolCall(name: tool, arguments: [:]))), capability: .context, tool: tool, arguments: [:]))
        }
    }
}
