import XCTest
@testable import MewponCore
@testable import MewponDesktop

final class PalettePresentationTests: XCTestCase {
    func testCompactIdleAndSuggestionsUseActualCommands() {
        XCTAssertEqual(PalettePresentation.resolve(input: "", entries: [], busy: false), .idle)
        XCTAssertEqual(PalettePresentation.idle.height, 80)
        XCTAssertTrue(PalettePresentation.suggestions(for: "Open").allSatisfy { $0.hasPrefix("Open") })
        XCTAssertTrue(PalettePresentation.suggestions(for: "").isEmpty)
        XCTAssertTrue(PalettePresentation.suggestions(for: "What is quantum mechanics?").isEmpty)
    }
    func testBoundedResponseAndTrivialToolFeedback() {
        let result = ToolResult(true, "macOS accepted the folder-open request.")
        let entries = [ChatEntry(role: "user", text: "Open Downloads"), ChatEntry(role: "tool", text: "", result: result), ChatEntry(role: "assistant", text: result.summary)]
        XCTAssertEqual(PalettePresentation.resolve(input: "", entries: entries, busy: false), .confirmation)
        let long = [ChatEntry(role: "user", text: "Explain"), ChatEntry(role: "assistant", text: String(repeating: "Paragraph. ", count: 5000))]
        let response = PalettePresentation.resolve(input: "", entries: long, busy: false)
        XCTAssertLessThanOrEqual(response.height, 568)
        XCTAssertEqual(PalettePresentation.resolve(input: "", entries: [ChatEntry(role: "user", text: "Explain")], busy: true), .working)
    }
    func testLongNativeSummaryGetsReadableResponseSpace() {
        let result=ToolResult(true,"macOS: Example\nMemory: 16 GB\nStorage: 100 GB\nBattery: 38%")
        let entries=[ChatEntry(role:"user",text:"btry lvl"),ChatEntry(role:"tool",text:result.summary,result:result),ChatEntry(role:"assistant",text:result.summary)]
        guard case .response=PalettePresentation.resolve(input:"",entries:entries,busy:false) else{return XCTFail("Do not clip multi-line native results into a one-line confirmation")}
    }
    func testOnlyCurrentTaskFilesControlLayout() {
        let result = ToolResult(true, "Results", items: [ResultItem(name: "fixture.pdf", path: "/tmp/fixture.pdf", kind: "pdf")])
        let old = [ChatEntry(role: "user", text: "Find PDF"), ChatEntry(role: "tool", text: "", result: result)]
        XCTAssertEqual(PalettePresentation.resolve(input: "", entries: old, busy: false), .files(1))
        let current = old + [ChatEntry(role: "user", text: "Explain recursion")]
        XCTAssertEqual(PalettePresentation.currentTurn(current).count, 1)
        XCTAssertEqual(PalettePresentation.resolve(input: "", entries: current, busy: true), .working)
    }
}
