import XCTest
@testable import MewponCore

final class MarkdownTests: XCTestCase {
    func testBlockFormsAndCodeLiteralSafety() {
        let source = "# Heading\n\nA **bold** paragraph with `code`.\n\n- First\n2. Second\n\n> Quote\n\n```swift\nlet x = \"<script>\"\n```\n\n| A | B |\n| --- | --- |\n| one | two |"
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.count, 7)
        XCTAssertEqual(blocks.first?.kind, .heading(1, "Heading"))
        XCTAssertTrue(blocks.contains { if case .code("swift", "let x = \"<script>\"") = $0.kind { return true }; return false })
        XCTAssertTrue(blocks.contains { if case .table(["A", "B"], [["one", "two"]]) = $0.kind { return true }; return false })
    }
    func testStreamingMatchesFullParseForEveryPrefix() {
        let text = "# Title\n\nParagraph.\n\n- one\n- two\n\n| A | B |\n| --- | --- |\n| one | two |\n\n```swift\nlet x = 42\nprint(x)\n```\n\nDone."
        var stream = StreamingMarkdown(), prefix = ""
        for character in text {
            prefix.append(character); stream.update(prefix)
            XCTAssertEqual(stream.blocks, MarkdownParser.parse(prefix), "Prefix: \(prefix)")
        }
        stream.update("replacement"); XCTAssertEqual(stream.blocks, MarkdownParser.parse("replacement"))
    }
    func testIncompleteCodeFenceKeepsCodeIdentity() {
        var stream = StreamingMarkdown(); stream.update("Hi\n\n```python\nx =")
        let id = stream.blocks.last?.id
        stream.update("Hi\n\n```python\nx = 1\n```")
        XCTAssertEqual(stream.blocks.last?.id, id)
        XCTAssertEqual(stream.blocks.last?.kind, .code("python", "x = 1"))
    }
}
