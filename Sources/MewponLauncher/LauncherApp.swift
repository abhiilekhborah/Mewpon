import AppKit
import CoreGraphics
import MewponShortcut

@MainActor final class LauncherDelegate: NSObject, NSApplicationDelegate {
    private let listener = MewSequenceListener(displayName: "Mewpon Launcher")
    private var gate = LauncherTriggerGate()
    private var timer: Timer?
    private var probe: NSObjectProtocol?
    private var mainURL: URL?
    private var requestedAccess = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let parent = LauncherIdentity.parentApplication(of: Bundle.main.bundleURL),
              Bundle(url: parent)?.bundleIdentifier == LauncherIdentity.mainBundleID else {
            NSApp.terminate(nil); return
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: LauncherIdentity.bundleID)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
            NSApp.terminate(nil); return
        }
        mainURL = parent
        NSApp.setActivationPolicy(.prohibited)
        ProcessInfo.processInfo.disableAutomaticTermination("Mewpon shortcut launcher")
        listener.toggle = { [weak self] in self?.launchIfNeeded() }
        listener.statusChanged = { [weak self] _ in self?.report() }
        probe = DistributedNotificationCenter.default().addObserver(forName: LauncherIdentity.probe, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Only retries an unavailable tap / newly granted permission; no model or UI work.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.listener.isListening { self.refresh() }
            }
        }
        refresh()
    }
    private var sequenceEnabled: Bool {
        CFPreferencesAppSynchronize(LauncherIdentity.mainBundleID as CFString)
        return CFPreferencesCopyAppValue("mewSequenceEnabled" as CFString, LauncherIdentity.mainBundleID as CFString) as? Bool ?? true
    }
    private func refresh() {
        let enabled = sequenceEnabled
        if enabled, !CGPreflightListenEventAccess(), !requestedAccess {
            requestedAccess = true
            _ = CGRequestListenEventAccess()
        }
        listener.refresh(enabled: enabled)
        report()
    }
    private func report() {
        DistributedNotificationCenter.default().postNotificationName(LauncherIdentity.status, object: String(ProcessInfo.processInfo.processIdentifier), userInfo: ["status": listener.status, "ready": listener.isListening], deliverImmediately: true)
    }
    private func launchIfNeeded() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: LauncherIdentity.mainBundleID).contains { !$0.isTerminated }
        guard let mainURL, gate.begin(mainAppRunning: running, sequenceEnabled: sequenceEnabled) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = [LauncherIdentity.launchArgument]
        config.activates = true
        config.addsToRecentItems = false
        // No path search or shell invocation: launch only our enclosing signed app.
        Task {
            defer { gate.finish() }
            do { _ = try await NSWorkspace.shared.openApplication(at: mainURL, configuration: config) }
            catch { NSLog("Mewpon Launcher: launch failed: %@", error.localizedDescription) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        listener.shutdown(); timer?.invalidate()
        if let probe { DistributedNotificationCenter.default().removeObserver(probe) }
    }
}

@main struct LauncherApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LauncherDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
