import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import ApplicationServices

@MainActor final class DesktopPreferences: ObservableObject {
    @Published var companion = UserDefaults.standard.object(forKey: "companionMode") as? Bool ?? true { didSet { UserDefaults.standard.set(companion, forKey: "companionMode"); changed?() } }
    @Published var visibility = UserDefaults.standard.string(forKey: "avatarVisibility") ?? "companion" { didSet { UserDefaults.standard.set(visibility, forKey: "avatarVisibility"); changed?() } }
    @Published var allSpaces = UserDefaults.standard.object(forKey: "allSpaces") as? Bool ?? false { didSet { UserDefaults.standard.set(allSpaces, forKey: "allSpaces"); changed?() } }
    @Published var fullscreen = UserDefaults.standard.object(forKey: "fullscreen") as? Bool ?? false { didSet { UserDefaults.standard.set(fullscreen, forKey: "fullscreen"); changed?() } }
    @Published var position = "custom"
    @Published var loginStatus = "Not checked"
    @Published var loginError: String?
    var changed: (() -> Void)?
    func refreshLogin() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "Enabled"
        case .requiresApproval: loginStatus = "Awaiting approval in Login Items"
        case .notRegistered: loginStatus = "Disabled"
        case .notFound: loginStatus = "App registration unavailable"
        @unknown default: loginStatus = "Unknown"
        }
    }
    func setLogin(_ enabled: Bool) {
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
                loginError = nil
            } catch { loginError = error.localizedDescription }
            refreshLogin()
        }
    }
}

@MainActor final class LocalNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var enabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    var onOpen: (() -> Void)?
    @Published var status = "Not checked"
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.onOpen?() }
    }
    func configure(_ enabled: Bool) {
        Task {
            if enabled {
                do { self.enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                catch { self.enabled = false; status = error.localizedDescription }
            } else { self.enabled = false; UNUserNotificationCenter.current().removeAllPendingNotificationRequests(); UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
            UserDefaults.standard.set(self.enabled, forKey: "notificationsEnabled")
            await refresh()
        }
    }
    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: status = "Authorized"
        case .denied: status = "Denied"
        case .notDetermined: status = "Not requested"
        @unknown default: status = "Unknown"
        }
    }
    func completed(failed: Bool, visible: Bool, duration: Double) {
        guard enabled, !visible, duration >= 10 else { return }
        let content = UNMutableNotificationContent()
        content.title = failed ? "Mewpon needs attention" : "Mewpon finished your task"
        content.body = "Open Mewpon to view the result on this Mac."
        // No prompts, file names, selected text, or model output in notification content.
        Task { do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) } catch { status = "Delivery failed: " + error.localizedDescription } }
    }
}

struct DesktopIntegrationSettings: View {
    @ObservedObject var preferences: DesktopPreferences
    @ObservedObject var notifications: LocalNotifications
    let place: (String) -> Void
    var body: some View {
        Section("Native integration") {
            Toggle("Companion mode · hide Dock icon", isOn: $preferences.companion)
            Picker("Avatar visibility", selection: $preferences.visibility) {
                Text("Companion").tag("companion"); Text("Assistant").tag("assistant"); Text("Hidden").tag("hidden")
            }
            Toggle("Avatar on every Space", isOn: $preferences.allSpaces)
            Toggle("Allow explicitly opened assistant in full screen", isOn: $preferences.fullscreen)
            Picker("Avatar placement", selection: $preferences.position) {
                Text("Custom drag position").tag("custom")
                ForEach(["bottom-left", "bottom-right", "top-left", "top-right"], id: \.self) { Text($0.capitalized).tag($0) }
            }.onChange(of: preferences.position) { _, value in if value != "custom" { place(value) } }
            HStack { Text("Launch at login: " + preferences.loginStatus); Spacer(); Button("Enable") { preferences.setLogin(true) }; Button("Disable") { preferences.setLogin(false) } }
            HStack { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }; Button("Refresh login status") { preferences.refreshLogin() } }
            if let error = preferences.loginError { Text(error).font(.caption).foregroundStyle(.orange) }
            Toggle("Notify when a background task finishes", isOn: Binding(get: { notifications.enabled }, set: notifications.configure))
            Text("Notifications: " + notifications.status).font(.caption)
            Text("Login and notification permissions are requested only when enabled here. Keep Mewpon in a stable location before enabling login.").font(.caption).foregroundStyle(.secondary)
        }.task { preferences.refreshLogin(); await notifications.refresh() }
    }
}
