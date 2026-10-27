import XCTest
import AppKit
import CoreText
@testable import MewponCore
@testable import MewponDesktop

final class ContentIndexTests:XCTestCase {
    func fixture() throws ->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("MewponIndexTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return URL(fileURLWithPath:LocalPath.canonical(root.path))
    }
    func pdf(_ url:URL) throws {
        let consumer=try XCTUnwrap(CGDataConsumer(url:url as CFURL));var rect=CGRect(x:0,y:0,width:612,height:792)
        let context=try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&rect,nil))
        context.beginPDFPage(nil)
        let text="Alex Example\nEducation: Computer Science\nExperience: Software internship\nSkills: Python Swift SQL\nProjects: Local desktop assistant"
        let attributed=NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:15)])
        let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),CFRange(location:0,length:0),CGPath(rect:CGRect(x:40,y:300,width:530,height:450),transform:nil),nil)
        CTFrameDraw(frame,context);context.endPDFPage();context.closePDF()
    }
    func testAuthorizedContentPurposeAndInvalidation() async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("Alex_Example_Final_2026.pdf");try pdf(url)
        let defaults=try XCTUnwrap(UserDefaults(suiteName:"MewponIndexTests-"+UUID().uuidString))
        // The isolated service indexes only this explicitly supplied test folder.
        let service=AuthorizedSearch(defaults:defaults)
        let before=try await service.search(.parse("cv pdf"));XCTAssertTrue(before.isEmpty)
        try await service.authorize(root)
        let found=try await service.search(.parse("cv pdf"));XCTAssertEqual(found.map(\.path),[url.path])
        let text=try LocalContent.read(url);XCTAssertTrue(text.contains("Education"))
        try await service.remember(try XCTUnwrap(found.first),alias:"application dossier")
        let aliases=try await service.search(.parse("dossier"));XCTAssertEqual(aliases.map(\.path),[url.path])
        try Data("changed".utf8).write(to:url)
        let stale=try await service.search(.parse("cv"));XCTAssertTrue(stale.isEmpty,"Changed content must not use stale purpose evidence")
        try await service.clear()
        let removed=try await service.search(.parse("dossier"));XCTAssertTrue(removed.isEmpty)
        let roots=await service.roots();XCTAssertTrue(roots.isEmpty)
    }
    func testFTSBoundsFuzzyTypeAndIsolation() async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let db=try ContentIndex(url:root.appendingPathComponent("index.sqlite"))
        for i in 0..<30 {
            let url=root.appendingPathComponent("internship-report-\(i).txt");try Data("Engineering placement".utf8).write(to:url)
            let values=try url.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey])
            try await db.upsert(.init(path:url.path,modified:values.contentModificationDate!,size:values.fileSize!,text:"internship report college"),root:root.path)
        }
        let found=try await db.search(.parse("internshp repot"),authorizedRoots:[root.path]);XCTAssertEqual(found.count,20)
        let outside=try await db.search(.parse("report"),authorizedRoots:[]);XCTAssertTrue(outside.isEmpty)
        let pdf=try await db.search(.parse("report pdf"),authorizedRoots:[root.path]);XCTAssertTrue(pdf.isEmpty)
        let injected=try await db.search(.parse("report\" OR *"),authorizedRoots:[root.path]);XCTAssertLessThanOrEqual(injected.count,20)
    }
    func testProjectDetectionNeverTraversesOutsideAuthorizedFolder() async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let project=root.appendingPathComponent("SmallProject");try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        try Data("print('fixture, never executed')".utf8).write(to:project.appendingPathComponent("main.py"))
        try Data("[project]".utf8).write(to:project.appendingPathComponent("pyproject.toml"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("outside"),withDestinationURL:URL(fileURLWithPath:NSHomeDirectory()))
        let service=AuthorizedSearch(defaults:try XCTUnwrap(UserDefaults(suiteName:UUID().uuidString)))
        try await service.authorize(root)
        let projects=await service.projects();XCTAssertEqual(projects.map(\.path),[project.path])
        try await service.clear()
    }
    func testRegisteredApplicationIdentityAllowsNonstandardLocationOnlyWhenExact() throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let app=root.appendingPathComponent("Fixture.app"),contents=app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"local.mewpon.test-registered-app","CFBundleName":"Fixture","CFBundlePackageType":"APPL"],format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
        XCTAssertNil(ApplicationRegistry.validatedPath(app.path))
        XCTAssertNil(ApplicationRegistry.validatedPath(app.path,registeredIdentifier:"com.example.other"))
        XCTAssertNotNil(ApplicationRegistry.validatedPath(app.path,registeredIdentifier:"local.mewpon.test-registered-app"))
    }
    func testRegisteredVSCodeLookupIfInstalled() async throws {
        let urls=await MainActor.run {NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.microsoft.VSCode")}
        guard urls != nil else{throw XCTSkip("VS Code is not registered in this environment")}
        let found=try await OpenApplicationTool.resolve("vscode")
        XCTAssertEqual(found.count,1)
        XCTAssertEqual(found.first.flatMap{Bundle(url:URL(fileURLWithPath:$0.path))?.bundleIdentifier},"com.microsoft.VSCode")
    }
    func testUnknownProjectAndMissingAliasAreRejected() async throws {
        let result=try await OpenProjectTool().execute(arguments:["path":.string("/private/tmp/not-an-authorized-project")])
        XCTAssertFalse(result.success)
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let db=try ContentIndex(url:root.appendingPathComponent("index.sqlite"))
        do {try await db.remember(path:root.appendingPathComponent("absent.pdf").path,alias:"cv");XCTFail("Must reject an unindexed alias")} catch {}
    }
    func testContentSearchBenchmark() async throws {
        guard let output=ProcessInfo.processInfo.environment["MEWPON_SEARCH_OUTPUT"] else{throw XCTSkip("Opt-in search benchmark")}
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("Alex_Example_Final_2026.pdf");try pdf(url)
        if let destination=ProcessInfo.processInfo.environment["MEWPON_SEARCH_FIXTURE_PATH"] {
            let target=URL(fileURLWithPath:destination)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try? FileManager.default.removeItem(at:target)
            try FileManager.default.copyItem(at:url,to:target)
        }
        let service=AuthorizedSearch(defaults:try XCTUnwrap(UserDefaults(suiteName:UUID().uuidString)))
        let start=ContinuousClock.now;try await service.authorize(root)
        var records:[[String:Any]]=[["operation":"initial_index_one_pdf","ms":elapsedMilliseconds(since:start)]]
        for text in ["cv pdf","education projects","internship"] {for i in 0..<100 {
            let start=ContinuousClock.now;let found=try await service.search(.parse(text))
            XCTAssertEqual(found.first?.path,url.path)
            records.append(["operation":"fts_search","query":text,"sample":i,"ms":elapsedMilliseconds(since:start),"matches":found.count])
        }}
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output));try await service.clear()
    }
}
