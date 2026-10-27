import XCTest
@testable import MewponCore
@testable import MewponDesktop

final class NativeTests: XCTestCase {
    func testNativeApplicationResolutionWithoutLaunching() async throws {
        XCTAssertEqual(OpenApplicationTool.bundleIdentifier(for: "Safari"), "com.apple.Safari")
        let matches = try await OpenApplicationTool.resolve("Finder")
        XCTAssertTrue(matches.contains(where: { $0.path.hasSuffix("Finder.app") }))
        let safari = try await OpenApplicationTool.resolve("Safari")
        XCTAssertTrue(safari.contains(where: { $0.path.hasSuffix("Safari.app") }))
        let missing = try await OpenApplicationTool.resolve("mewpon-no-such-app-" + UUID().uuidString)
        XCTAssertTrue(missing.isEmpty)
    }
    func testMeasuredSystemInformation() async throws {
        let result = try await SystemInfoTool().execute(arguments: [:])
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.summary.contains("Physical memory:"))
        XCTAssertTrue(result.summary.contains("macOS:"))
        XCTAssertTrue(result.summary.contains("Storage"))
    }
    func testNonexistentAndExecutablePathsAreRejected() async throws {
        let tool = OpenFileTool()
        let missing = try await tool.execute(arguments: ["path": .string("/tmp/mewpon-missing-" + UUID().uuidString)])
        XCTAssertFalse(missing.success)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for ext in ["command", "workflow", "scpt", "html", "webloc", "py"] {
            let file = directory.appendingPathComponent("unsafe." + ext)
            try Data("test".utf8).write(to: file)
            let result = try await tool.execute(arguments: ["path": .string(file.path)])
            XCTAssertFalse(result.success, ext)
        }
    }
    @MainActor func testScopedSpotlightQuery() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let result = try await SpotlightSearch(scopes: [root]).search("Package.swift")
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.items.allSatisfy { $0.path.hasPrefix(root + "/") && FileManager.default.fileExists(atPath: $0.path) })
        // A new or unindexed checkout can legitimately have no indexed matches.
    }
    @MainActor func testSpotlightTypeDateFiltersAndCancellation() async throws {
        for term in ["PDFs named report","PDFs from last week","Python file named main","recent presentations"] {
            let result=try await SpotlightSearch().search(term)
            XCTAssertTrue(result.success,term)
            if term.hasPrefix("PDFs"){XCTAssertTrue(result.items.allSatisfy{$0.path.lowercased().hasSuffix(".pdf")})}
        }
        let search=SpotlightSearch()
        let task=Task{try await search.search("MewponAbsentFixture")}
        task.cancel()
        do{_ = try await task.value;XCTFail("Expected cancellation")}catch{XCTAssertTrue(error is CancellationError)}
    }
    func testLateNativeOpenCallbackCannotResumeCancelledRequest() async throws {
        let completion=NativeOpenCompletion()
        let request=Task{try await withCheckedThrowingContinuation{(c:CheckedContinuation<ToolResult,Error>) in _ = completion.install(c)}}
        completion.cancel()
        do{_ = try await request.value;XCTFail("Expected cancellation")}catch{XCTAssertTrue(error is CancellationError)}
        completion.complete(.success(ToolResult(true,"Late result")))
    }
    @MainActor func testPermissionManagerDenialAndCancellation() async throws {
        let permissions = PermissionManager()
        let task = Task { await permissions.authorize(.launchApplication, tool: "open_application", arguments: ["application": .string("Safari")]) }
        await Task.yield()
        XCTAssertNotNil(permissions.pending)
        permissions.resolve(false)
        let allowed = await task.value; XCTAssertFalse(allowed)
        let deniedAgain = await permissions.authorize(.launchApplication, tool: "open_application", arguments: ["application": .string("Safari")])
        XCTAssertFalse(deniedAgain)
        permissions.beginRequest()
        let cancelled = Task { await permissions.authorize(.searchFiles, tool: "search_files", arguments: ["query": .string("test")]) }
        await Task.yield(); cancelled.cancel()
        let result = await cancelled.value; XCTAssertFalse(result); XCTAssertNil(permissions.pending)
    }
}
