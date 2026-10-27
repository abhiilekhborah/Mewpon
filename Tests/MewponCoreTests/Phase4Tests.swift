import XCTest
import AppKit
import MewponCore
@testable import MewponDesktop

final class Phase4Tests: XCTestCase {
    func testLauncherPlacementOnOffsetAndSmallDisplays() {
        for screen in [NSRect(x: 0, y: 40, width: 1512, height: 900), NSRect(x: -1920, y: 0, width: 1920, height: 1000), NSRect(x: 0, y: 1000, width: 500, height: 300)] {
            let frame = CommandPalette.placement(size: NSSize(width: 620, height: 430), visible: screen)
            XCTAssertTrue(screen.contains(frame)); XCTAssertEqual(frame.midX, screen.midX)
        }
    }
    func testSearchDateFiltersAndKinds() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_792_368_000) // fixed date; use calendar arithmetic rather than current clock
        let yesterday = FileSearchQuery.parse("PDFs from yesterday")
        XCTAssertEqual(yesterday.name, ""); XCTAssertEqual(yesterday.extensions, ["pdf"])
        let interval = try XCTUnwrap(yesterday.modifiedInterval(now: now, calendar: calendar))
        XCTAssertEqual(interval.end, calendar.startOfDay(for: now)); XCTAssertEqual(interval.duration, 86400)
        XCTAssertTrue(FileSearchQuery.parse("screenshots from this month").screenshots)
        XCTAssertEqual(FileSearchQuery.parse("presentation i edited last week").extensions, ["ppt", "pptx", "key"])
        XCTAssertTrue(FileSearchQuery.parse("largest videos").largest)
        XCTAssertEqual(FileSearchQuery.parse("largest videos").extensions, ["mov", "mp4", "m4v"])
        XCTAssertEqual(FileSearchQuery.parse("everything named project").name, "project")
    }
    func testSystemRoutingDoesNotBypassConservativeGrammar() {
        for command in ["Switch to Safari", "Hide Safari", "Quit Safari", "Set volume to 45%", "Open sound settings", "Wi-Fi status", "Find PDFs from yesterday", "Show screenshots from this month"] {
            guard case .deterministic = FastIntentRouter.classify(command) else { return XCTFail(command) }
        }
        for command in ["Don't quit Safari", "If I say quit Safari", "Explain how to set volume to 45", "quit Safari and Finder", "set volume to 101"] {
            XCTAssertEqual(FastIntentRouter.classify(command), .requiresLLM, command)
        }
    }
    @MainActor func testSpotlightFindsIndexedFixture() async throws {
        guard ProcessInfo.processInfo.environment["MEWPON_PHASE4_FIXTURE"] == "1" else { throw XCTSkip("Index Verification/Phase4/mewpon-phase4-fixture.pdf with mdimport and set MEWPON_PHASE4_FIXTURE=1") }
        let result = try await SpotlightSearch().search(FileSearchQuery.parse("PDFs named mewpon-phase4"))
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.items.contains { $0.name == "mewpon-phase4-fixture.pdf" }, result.summary)
    }
    func testNativeToolsRejectBadArgumentsWithoutChangingAnything() async throws {
        let badVolume = try await VolumeTool().execute(arguments: ["level": .string("101")])
        XCTAssertFalse(badVolume.success)
        let badApp = try await ApplicationControlTool().execute(arguments: ["application": .string("Finder"), "action": .string("forceQuit")])
        XCTAssertFalse(badApp.success)
        let missing = try await FinderActionTool().execute(arguments: ["path": .string("/private/tmp/mewpon-phase4-no-such-file"), "action": .string("preview")])
        XCTAssertFalse(missing.success)
        let badContext = try await ContextTool().execute(arguments: ["kind": .string("passwords")])
        XCTAssertFalse(badContext.success)
    }
    func testNewToolsRemainBehindAuthorization() async {
        let router = ToolRouter(tools: [ApplicationControlTool(), FinderActionTool(), ContextTool(), VolumeTool()])
        for call in [ToolCall(name: "application_control", arguments: ["application": .string("Finder"), "action": .string("quit")]), ToolCall(name: "read_context", arguments: ["kind": .string("clipboard")]), ToolCall(name: "output_volume", arguments: ["level": .string("70")]), ToolCall(name: "finder_action", arguments: ["path": .string("/private/tmp"), "action": .string("reveal")])] {
            let result = await router.execute(call) { _, _, _ in false }
            XCTAssertFalse(result.success); XCTAssertTrue(result.summary.contains("Permission denied"))
        }
    }
    @MainActor func testNativeApprovalDialogDenialAndCancellation() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let manager = PermissionManager()
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let presenter = PermissionPresenter(manager: manager, parent: { panel })
        defer { withExtendedLifetime(presenter) {}; panel.orderOut(nil); panel.close() }
        for decision in ["deny", "allow", "cancel", "forged-response"] {
            manager.beginRequest()
            let finished = expectation(description: "Native approval returned")
            let task = Task { @MainActor in
                let approved = await manager.authorize(.launchApplication, tool: "open_application", arguments: ["application": .string("Missing verification app")])
                XCTAssertEqual(approved, decision == "allow"); finished.fulfill()
            }
            let attached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in panel.attachedSheet != nil }, object: panel)
            await fulfillment(of: [attached], timeout: 3)
            if decision == "cancel" { task.cancel() }
            else if decision == "forged-response" { panel.endSheet(try XCTUnwrap(panel.attachedSheet), returnCode: .alertSecondButtonReturn) }
            else {
                func button(in view: NSView, title: String) -> NSButton? {
                    if let button = view as? NSButton, button.title == title { return button }
                    return view.subviews.lazy.compactMap { button(in: $0, title: title) }.first
                }
                let sheet = try XCTUnwrap(panel.attachedSheet)
                let target = try XCTUnwrap(button(in: try XCTUnwrap(sheet.contentView), title: decision == "allow" ? "Allow once" : "Deny"))
                target.performClick(nil)
            }
            await fulfillment(of: [finished], timeout: 3)
            XCTAssertNil(manager.pending)
        }
    }
    @MainActor func testCollapsedCompanionCannotTakeKeyboardFocus() {
        let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.acceptsKeyboard = false; XCTAssertFalse(panel.canBecomeKey)
        panel.acceptsKeyboard = true; XCTAssertTrue(panel.canBecomeKey)
        panel.close()
    }
}
