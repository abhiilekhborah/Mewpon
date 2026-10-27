import AppKit
import SwiftUI
import ServiceManagement
import MewponShortcut

@MainActor final class BackgroundShortcutLauncher: ObservableObject {
    private let service = SMAppService.loginItem(identifier: LauncherIdentity.bundleID)
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Disabled"
    @Published private(set) var helperStatus = ""
    private var observer: NSObjectProtocol?
    init() {
        observer = DistributedNotificationCenter.default().addObserver(forName: LauncherIdentity.status, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let pid = notification.object as? String,
                      NSRunningApplication.runningApplications(withBundleIdentifier: LauncherIdentity.bundleID).contains(where: { String($0.processIdentifier) == pid && $0.bundleURL?.standardizedFileURL.path == Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/MewponLauncher.app").standardizedFileURL.path }) else { return }
                self.helperStatus = notification.userInfo?["status"] as? String ?? ""
            }
        }
    }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }
    func refresh() {
        switch service.status {
        case .enabled: enabled = true; status = "Launcher enabled · available after Quit and at login"
        case .requiresApproval: enabled = true; status = "Approve Mewpon Launcher in Login Items"
        case .notRegistered: enabled = false; status = "Disabled"
        case .notFound: enabled = false; status = "Launcher registration unavailable"
        @unknown default: enabled = false; status = "Unknown launcher status"
        }
        DistributedNotificationCenter.default().postNotificationName(LauncherIdentity.probe, object: nil, userInfo: nil, deliverImmediately: true)
    }
    func configure(_ value: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if value {
                    if service.status != .enabled { try service.register() }
                } else {
                    try await service.unregister()
                    let helperPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/MewponLauncher.app").standardizedFileURL.path
                    for helper in NSRunningApplication.runningApplications(withBundleIdentifier: LauncherIdentity.bundleID) where helper.bundleURL?.standardizedFileURL.path == helperPath {
                        helper.terminate()
                    }
                    helperStatus = ""
                }
                refresh()
            } catch { refresh(); status = error.localizedDescription }
        }
    }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

struct BackgroundShortcutSettings: View {
    @ObservedObject var launcher: BackgroundShortcutLauncher
    var body: some View {
        Toggle("Open Mewpon after quitting", isOn: Binding(get: { launcher.enabled }, set: launcher.configure)).disabled(launcher.busy)
        Text(launcher.status).font(.caption).foregroundStyle(.secondary)
        if launcher.enabled {
            Text("A small Mewpon Launcher stays running after Quit. Approve its Input Monitoring access once; no typed text is recorded. Disable this setting to stop it.").font(.caption).foregroundStyle(.secondary)
            if !launcher.helperStatus.isEmpty { Text("Launcher: " + launcher.helperStatus).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Refresh launcher") { launcher.refresh() }
                Button("Login Items…") { launcher.openLoginItems() }
            }
        }
    }
}
