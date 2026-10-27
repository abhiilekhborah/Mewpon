import XCTest
import AppKit
import SwiftUI
@testable import MewponCore
@testable import MewponDesktop

final class PaletteUITests: XCTestCase {
    func testTranscriptHidesDuplicateSummaryWithoutChangingHistory() {
        let result = ToolResult(true, "Found 20 matching files.")
        let history = [ChatEntry(role: "user", text: "Find reports"), ChatEntry(role: "tool", text: "", result: result), ChatEntry(role: "assistant", text: result.summary), ChatEntry(role: "user", text: result.summary)]
        let displayed = PaletteTranscript.entries(history)
        XCTAssertEqual(displayed.count, 3)
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(displayed.last?.role, "user")
    }
    @MainActor func testProgressiveSingleResultReservesVisibleRow() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model=AssistantModel(startsServices:false)
        let palette=CommandPalette(model:model)
        defer{palette.panel.orderOut(nil)}
        palette.show()
        model.entries=[ChatEntry(role:"user",text:"fnd my cv pdf")];model.busy=true
        await Task.yield()
        var result=ToolResult(true,"Initial matches",items:[.init(name:"Example.pdf",path:"/fixture/Example.pdf",kind:"pdf")]);result.partial=true
        model.entries.append(ChatEntry(role:"tool",text:result.summary,result:result))
        model.busy=false
        let height=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in abs(palette.panel.frame.height-PalettePresentation.files(1).height)<1},object:nil)
        await fulfillment(of:[height],timeout:3)
        XCTAssertGreaterThanOrEqual(palette.panel.contentView?.frame.height ?? 0,200)
    }
    @MainActor func testNativeDragAndResizeConfigurationAndRenderResults() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AssistantModel(startsServices: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mewpon-results-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try (1...20).map { index -> ResultItem in
            let url = root.appendingPathComponent(index == 1 ? "My CV.pdf" : "Project report \(index).pdf")
            try Data().write(to: url)
            return ResultItem(name: url.lastPathComponent, path: url.path, kind: "pdf")
        }
        var result = ToolResult(true, "Found 20 matching files. Choose the intended path if several match. Results may be incomplete.", items: items)
        result.partial = true
        model.entries = [ChatEntry(role: "user", text: "Find my reports"), ChatEntry(role: "tool", text: "", result: result), ChatEntry(role: "assistant", text: result.summary)]
        let palette = CommandPalette(model: model)
        let window = palette.panel
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.isMovable)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize.width, 520)
        let drag = WindowDragView(); XCTAssertTrue(drag.mouseDownCanMoveWindow)
        XCTAssertTrue(drag.acceptsFirstMouse(for: nil))
        window.setFrame(NSRect(x: 40, y: 50, width: 600, height: 478), display: false)
        window.appearance = NSAppearance(named: .aqua)
        app.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView)
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.white.cgColor
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/Phase4/results-ui.png")
        // Material backdrops are supplied by WindowServer, outside view caching.
        // Composite over the native window color for an opaque layout proof.
        let proof = NSImage(size: host.bounds.size)
        proof.lockFocus(); NSColor.white.setFill(); host.bounds.fill()
        bitmap.draw(in: host.bounds); proof.unlockFocus()
        let opaque = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(proof.tiffRepresentation)))
        try XCTUnwrap(opaque.representation(using: .png, properties: [:])).write(to: output)
        XCTAssertGreaterThan(bitmap.pixelsWide, 500)
    }
}
