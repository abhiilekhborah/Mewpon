import XCTest
import AppKit
import CoreText
import Carbon
import MewponCore
@testable import MewponDesktop

final class Phase4CompletionTests: XCTestCase {
    func testCarbonShortcutPacketValidationAndNativeDispatch() throws {
        final class Probe { var received: UInt32? }
        let probe = Probe()
        var handler: EventHandlerRef?
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(probe).toOpaque()
        XCTAssertEqual(InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context, let id = ShortcutEvent.action(event) else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().received = id
            return noErr
        }, 1, &specification, context, &handler), noErr)
        defer { if let handler { RemoveEventHandler(handler) } }
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event), noErr)
        let packet = try XCTUnwrap(event); defer { ReleaseEvent(packet) }
        var identifier = EventHotKeyID(signature: ShortcutEvent.signature, id: 1)
        XCTAssertEqual(SetEventParameter(packet, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        XCTAssertEqual(SendEventToEventTarget(packet, GetEventDispatcherTarget()), noErr)
        XCTAssertEqual(probe.received, 1)
        identifier.id=5
        XCTAssertEqual(SetEventParameter(packet,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),MemoryLayout<EventHotKeyID>.size,&identifier),noErr)
        XCTAssertEqual(ShortcutEvent.action(packet),5)
        identifier.id=999
        XCTAssertEqual(SetEventParameter(packet,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),MemoryLayout<EventHotKeyID>.size,&identifier),noErr)
        XCTAssertNil(ShortcutEvent.action(packet))
        identifier.signature = 0
        XCTAssertEqual(SetEventParameter(packet, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        XCTAssertNil(ShortcutEvent.action(packet))
    }
    func testLocalTextAndPDFExtractionNeverExecutesContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("example.sh")
        try "echo do-not-execute; rm -rf example-test-only".write(to: url, atomically: true, encoding: .utf8)
        let result = try await ReadDocumentTool().execute(arguments: ["path": .string(url.path)])
        XCTAssertTrue(result.success); XCTAssertTrue(result.summary.contains("do-not-execute"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/Phase4/mewpon-phase4-fixture.pdf")
        let pdf = try LocalContent.read(fixture)
        XCTAssertTrue(pdf.contains("Mewpon Phase 4 local test file"))
        XCTAssertTrue(LocalContent.bounded(String(repeating: "x", count: 3100)).contains("Excerpt limited"))
    }
    func testLocalOCRRecognizesControlledFixture() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 900, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 900, height: 200))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "MEWPON TEST OCR 145", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 42, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        context.textPosition = CGPoint(x: 30, y: 90); CTLineDraw(line, context)
        let text = try LocalContent.recognize(try XCTUnwrap(context.makeImage()))
        XCTAssertTrue(text.uppercased().contains("MEWPON"), text); XCTAssertTrue(text.contains("145"), text)
    }
    func testNewContentToolsRequirePermissionBeforeReading() async {
        let router = ToolRouter(tools: [ReadDocumentTool(), ScreenTextTool()])
        for call in [ToolCall(name: "read_document", arguments: ["path": .string("/not/a/real/path")]), ToolCall(name: "read_screen_text", arguments: [:])] {
            let result = await router.execute(call) { _, _, _ in false }
            XCTAssertTrue(result.summary.contains("Permission denied"))
        }
    }
    @MainActor func testPermissionIDsRejectStaleCallbacksAndConcurrentRequests() async throws {
        let manager = PermissionManager(); manager.beginRequest()
        let first = Task { @MainActor in await manager.authorize(.context, tool: "read_context", arguments: ["kind": .string("clipboard")]) }
        await Task.yield()
        let id = try XCTUnwrap(manager.pending?.id)
        manager.resolve(true, requestID: UUID()); XCTAssertEqual(manager.pending?.id, id)
        let competing = await manager.authorize(.openPath, tool: "open_path", arguments: ["path": .string("/tmp")])
        XCTAssertFalse(competing); XCTAssertEqual(manager.pending?.id, id)
        manager.resolve(false, requestID: id)
        let approved = await first.value; XCTAssertFalse(approved); XCTAssertEqual(manager.lastDecision, false)
    }
    @MainActor func testLifecycleReplayAndDisplayRemovalRecovery() {
        var events: [String] = []
        let lifecycle = DesktopLifecycle { event in
            switch event { case .sleep: events.append("sleep"); case .wake: events.append("wake"); case .displaysChanged: events.append("displays"); case .spaceChanged: events.append("space"); case .otherApplicationActivated: events.append("application") }
        }
        lifecycle.handle(.sleep); lifecycle.handle(.wake); lifecycle.handle(.displaysChanged)
        XCTAssertEqual(events, ["sleep", "wake", "displays"])
        let remaining = CGRect(x: 0, y: 40, width: 1000, height: 600)
        let recovered = WindowGeometry.recovered(CGRect(x: -1920, y: 900, width: 500, height: 800), displays: [remaining])
        XCTAssertTrue(remaining.contains(recovered))
        let offset = CGRect(x: -1200, y: 600, width: 1200, height: 700)
        XCTAssertTrue(offset.contains(WindowGeometry.recovered(CGRect(x: -900, y: 650, width: 220, height: 176), displays: [remaining, offset])))
    }
    @MainActor func testDroppedImageValidationAndCleanup() throws {
        XCTAssertThrowsError(try DroppedContent.shared.stageImage(Data("bad image".utf8)))
        XCTAssertEqual(DroppedContent.url("file:///tmp/example.txt" as NSString)?.path, "/tmp/example.txt")
        let image = NSImage(size: NSSize(width: 32, height: 32)); image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        let url = try DroppedContent.shared.stageImage(data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        DroppedContent.shared.cleanup(); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
