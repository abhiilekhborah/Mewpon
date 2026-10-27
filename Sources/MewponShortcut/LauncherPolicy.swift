import Foundation

public enum LauncherIdentity {
    public static let bundleID = "local.mewpon.desktop.launcher"
    public static let mainBundleID = "local.mewpon.desktop"
    public static let launchArgument = "--mew-shortcut-launch"
    public static let probe = Notification.Name("local.mewpon.launcher.probe")
    public static let status = Notification.Name("local.mewpon.launcher.status")
    public static func parentApplication(of helper: URL) -> URL? {
        guard helper.isFileURL,
              Array(helper.pathComponents.suffix(4)) == ["Contents", "Library", "LoginItems", "MewponLauncher.app"] else { return nil }
        var parent = helper
        for _ in 0..<4 { parent.deleteLastPathComponent() }
        return parent.pathExtension == "app" ? parent : nil
    }
}

/// Main app handles toggling. The helper only launches a fully stopped main app.
public struct LauncherTriggerGate {
    public private(set) var launching = false
    public init() {}
    public mutating func begin(mainAppRunning: Bool, sequenceEnabled: Bool) -> Bool {
        guard !mainAppRunning, sequenceEnabled, !launching else { return false }
        launching = true
        return true
    }
    public mutating func finish() { launching = false }
}
