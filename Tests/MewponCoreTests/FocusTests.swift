import XCTest
import AppKit
@testable import MewponDesktop

final class FocusTests: XCTestCase {
    func testExpansionStaysInsideDisplayAndPreservesTopWhenPossible() {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1073)
        let compact = CGRect(x: 1437, y: 700, width: 220, height: 176)
        let expanded = WindowGeometry.constrained(compact, size: CGSize(width: 500, height: 662), visible: screen)
        XCTAssertEqual(expanded.minX, 1210)
        XCTAssertEqual(expanded.maxY, compact.maxY)
        XCTAssertTrue(screen.contains(expanded))
        let small = CGRect(x: -900, y: 0, width: 900, height: 600)
        XCTAssertTrue(small.contains(WindowGeometry.constrained(compact, size: CGSize(width: 500, height: 900), visible: small)))
    }
    @MainActor func testFocusFollowsWindowAttachmentAndRepeatedActivation() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let focus = ComposerFocus()
        let panel = FloatingPanel(contentRect: NSRect(x: 30, y: 30, width: 320, height: 100), styleMask: [.titled, .fullSizeContentView, .miniaturizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil); panel.close() }
        focus.request() // A request before mounting must survive until attachment/key.
        let editor = CommandTextView(frame: panel.contentLayoutRect)
        editor.focus = focus; panel.contentView = editor
        app.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); focus.fulfill()
        XCTAssertTrue(panel.firstResponder === editor)
        editor.string = "draft"
        for _ in 0..<12 {
            panel.orderOut(nil); focus.cancel(); panel.makeFirstResponder(nil)
            panel.makeKeyAndOrderFront(nil); focus.request()
            XCTAssertTrue(panel.firstResponder === editor)
            XCTAssertEqual(editor.string, "draft")
        }
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
        panel.miniaturize(nil)
        let minimized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in panel.isMiniaturized }, object: panel)
        await fulfillment(of: [minimized], timeout: 5)
        XCTAssertTrue(panel.isMiniaturized)
        panel.deminiaturize(nil)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !panel.isMiniaturized }, object: panel)
        await fulfillment(of: [restored], timeout: 5)
        panel.makeKeyAndOrderFront(nil); focus.request()
        XCTAssertTrue(panel.firstResponder === editor)
    }
    @MainActor func testReturnShiftReturnAndComposition() throws {
        let editor = CommandTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        var submissions = 0; editor.submit = { submissions += 1 }
        func enter(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        editor.string = "draft"; editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.keyDown(with: enter(.shift)); XCTAssertEqual(editor.string, "draft\n"); XCTAssertEqual(submissions, 0)
        editor.keyDown(with: enter()); XCTAssertEqual(submissions, 1)
        editor.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.keyDown(with: enter()); XCTAssertEqual(submissions, 1, "IME commit must not submit the chat")
    }
}
