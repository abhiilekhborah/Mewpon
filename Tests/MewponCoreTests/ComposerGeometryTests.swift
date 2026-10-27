import XCTest
import AppKit
@testable import MewponDesktop

final class ComposerGeometryTests: XCTestCase {
    @MainActor func testInputGeometry() async throws {
        _ = NSApplication.shared
        let model = AssistantModel(startsServices: false)
        let palette = CommandPalette(model: model)
        defer { palette.panel.orderOut(nil) }
        palette.show()
        try await Task.sleep(for: .milliseconds(250))
        func find(_ v: NSView) -> CommandTextView? { if let e = v as? CommandTextView { return e }; return v.subviews.compactMap(find).first }
        let editor = try XCTUnwrap(find(palette.panel.contentView!))
        let origin = editor.textContainerOrigin
        let frame = editor.frame
        editor.insertText("Check alignment", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(editor.textContainerOrigin, origin)
        XCTAssertEqual(editor.frame, frame)
    }
}
