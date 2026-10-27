import XCTest
import AppKit
@testable import MewponDesktop

final class WindowVisibilityTests: XCTestCase {
    @MainActor func testExplicitToggleAndBackgroundEventsNeverSummon() {
        let visibility = WindowVisibilityCoordinator(initial: .hidden)
        var persisted: [WindowVisibilityCoordinator.State] = []
        visibility.persist = { persisted.append($0) }
        visibility.send(.toggle); XCTAssertEqual(visibility.effective, .assistant)
        visibility.send(.toggle); XCTAssertEqual(visibility.effective, .hidden)
        for event in [WindowVisibilityCoordinator.Event.responseCompleted, .wake, .workspaceChanged] { visibility.send(event); XCTAssertEqual(visibility.effective, .hidden) }
        XCTAssertEqual(persisted, [.assistant, .hidden])
        for _ in 0..<101 { visibility.send(.toggle) }
        XCTAssertEqual(visibility.effective, .assistant)
        visibility.send(.escape); XCTAssertEqual(visibility.effective, .hidden)
    }
    @MainActor func testSuppressionPreservesIntentWithoutAutomaticRestore() {
        let visibility = WindowVisibilityCoordinator(initial: .companion)
        visibility.send(.sleep)
        XCTAssertEqual(visibility.requested, .companion); XCTAssertTrue(visibility.suppressed)
        visibility.send(.wake); visibility.send(.responseCompleted)
        XCTAssertEqual(visibility.effective, .hidden)
        visibility.send(.toggle); XCTAssertEqual(visibility.effective, .assistant)
        visibility.send(.sleep); XCTAssertEqual(visibility.effective, .hidden)
        visibility.send(.hide); XCTAssertEqual(visibility.requested, .hidden)
        visibility.send(.companion); XCTAssertEqual(visibility.effective, .companion)
    }
    @MainActor func testClickAwayAndSpaceChangesPreserveExplicitVisibility() {
        let visibility = WindowVisibilityCoordinator(initial: .hidden)
        var updates = 0
        visibility.changed = { _, _ in updates += 1 }
        visibility.send(.toggle)
        XCTAssertEqual(visibility.effective, .assistant)
        for _ in 0..<30 { visibility.send(.workspaceChanged) }
        XCTAssertEqual(visibility.effective, .assistant)
        XCTAssertFalse(visibility.suppressed)
        XCTAssertEqual(updates, 1, "Focus changes must not hide, animate, or activate windows")
        visibility.send(.toggle)
        XCTAssertEqual(visibility.effective, .hidden)
        visibility.send(.workspaceChanged)
        visibility.send(.responseCompleted)
        XCTAssertEqual(visibility.effective, .hidden)
        XCTAssertEqual(updates, 2)
    }
    @MainActor func testInterruptedNativeTransitionEndsWithoutInvisibleHitTarget() async throws {
        _ = NSApplication.shared
        let panel = FloatingPanel(contentRect: NSRect(x: 20, y: 40, width: 220, height: 176), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let transition = WindowTransition()
        let original = panel.frame
        for _ in 0..<10 { transition.set(panel, visible: true); transition.set(panel, visible: false) }
        XCTAssertTrue(panel.ignoresMouseEvents)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !panel.isVisible }, object: nil)
        await fulfillment(of: [hidden], timeout: 3)
        XCTAssertFalse(panel.isVisible); XCTAssertEqual(panel.frame, original)
        transition.set(panel, visible: true); XCTAssertFalse(panel.ignoresMouseEvents)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in panel.alphaValue == 1 }, object: nil)
        await fulfillment(of: [shown], timeout: 3)
        XCTAssertTrue(panel.isVisible); XCTAssertEqual(panel.alphaValue, 1)
        panel.orderOut(nil)
    }
}
