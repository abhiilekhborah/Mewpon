import XCTest
import MewponShortcut

final class LauncherTests: XCTestCase {
    func testLauncherOnlyStartsStoppedAppAndCoalescesRepeatedSequences() {
        var gate = LauncherTriggerGate()
        XCTAssertFalse(gate.begin(mainAppRunning: true, sequenceEnabled: true), "Main app owns show/hide; helper must not reopen it")
        XCTAssertFalse(gate.begin(mainAppRunning: false, sequenceEnabled: false))
        XCTAssertTrue(gate.begin(mainAppRunning: false, sequenceEnabled: true))
        XCTAssertFalse(gate.begin(mainAppRunning: false, sequenceEnabled: true), "No concurrent cold launches")
        gate.finish()
        XCTAssertTrue(gate.begin(mainAppRunning: false, sequenceEnabled: true), "Available again after a later Quit")
    }
    func testOnlyEnclosingAppCanBeLaunched() {
        let app = URL(fileURLWithPath: "/Applications/Example Folder/Mewpon.app", isDirectory: true)
        XCTAssertEqual(LauncherIdentity.parentApplication(of: app.appendingPathComponent("Contents/Library/LoginItems/MewponLauncher.app")), app)
        for path in ["/tmp/MewponLauncher.app", "/Applications/Other/Contents/Library/LoginItems/MewponLauncher.app", "/Applications/Mewpon.app/Contents/Helpers/MewponLauncher.app", "/Applications/Mewpon.app/Contents/Library/LoginItems/Other.app"] {
            XCTAssertNil(LauncherIdentity.parentApplication(of: URL(fileURLWithPath: path)), path)
        }
    }
}
