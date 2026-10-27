import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers
import MewponCore

struct AutomationRecord: Codable, Identifiable {
    var id = UUID(); let date: Date; let tool: String; let success: Bool
}
@MainActor final class AutomationPreferences: ObservableObject {
    @Published var policy: AutomationTrustPolicy {
        didSet {
            if let data = try? JSONEncoder().encode(policy) { UserDefaults.standard.set(data, forKey: "automationPolicyV6") }
            if !policy.enabled { disabled?() }
        }
    }
    @Published private(set) var records: [AutomationRecord] = []
    var disabled: (() -> Void)?
    init() {
        policy = UserDefaults.standard.data(forKey: "automationPolicyV6").flatMap { try? JSONDecoder().decode(AutomationTrustPolicy.self, from: $0) } ?? AutomationTrustPolicy()
    }
    func record(_ tool: String, success: Bool) { records.insert(.init(date: Date(), tool: tool, success: success), at: 0); records = Array(records.prefix(30)) }
    func authorizeFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose a folder for scoped file operations. You can revoke it here."
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != "/", path != NSHomeDirectory(), !policy.folders.contains(path) else { return }
            policy.folders.append(path)
        }
    }
    func authorizeApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url) {
            for value in [bundle.bundleIdentifier, bundle.object(forInfoDictionaryKey: "CFBundleName") as? String].compactMap({ $0 }) where !policy.applications.contains(value) { policy.applications.append(value) }
        }
    }
}
struct AutomationSettings: View {
    @ObservedObject var preferences: AutomationPreferences
    @State private var refresh = 0
    @AppStorage("translationModeV7") private var translationMode="automatic"
    var body: some View {
        Form {
            Section("Automation & Permissions") {
                Toggle("Enable automation", isOn: $preferences.policy.enabled)
                Text("Configure once for ordinary tasks. macOS permissions remain separate. Context reads still ask for each task; destructive and arbitrary-code tools are unavailable.").font(.caption).foregroundStyle(.secondary)
                ForEach(AutomationFeature.allCases, id: \.self) { feature in
                    Picker(feature.title, selection: Binding(get: { preferences.policy.rule(feature) }, set: { preferences.policy.rules[feature.rawValue] = $0 })) {
                        Text("Ask every time").tag(TrustRule.ask)
                        if feature != .context && feature != .scripts && feature != .communication { Text("Allow").tag(TrustRule.allow); Text("Selected folders/apps").tag(TrustRule.scoped) }
                        Text("Deny").tag(TrustRule.deny)
                    }
                }
            }
            Section("Authorized scopes · revoke any time") {
                Button("Add operation folder…") { preferences.authorizeFolder() }
                ForEach(preferences.policy.folders, id: \.self) { path in HStack { Text(path).font(.caption); Spacer(); Button("Revoke") { preferences.policy.folders.removeAll { $0 == path } } } }
                Button("Add application…") { preferences.authorizeApplication() }
                ForEach(preferences.policy.applications, id: \.self) { app in HStack { Text(app).font(.caption); Spacer(); Button("Revoke") { preferences.policy.applications.removeAll { $0 == app } } } }
                Text("File search/content access has its own folder picker in Privacy. File mutations always require an operation folder above, including when approval is set to Allow.").font(.caption)
            }
            Section("macOS access · requested only when needed") {
                Text("Accessibility: " + (AXIsProcessTrusted() ? "Granted" : "Not granted"))
                Button("Enable window-control access…") { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary); refresh += 1 }
                Button("Refresh access status") { refresh += 1 }
                Text("Application-specific Apple Events may prompt on first use. Screen OCR uses the macOS capture picker. Notifications are configured in General. Microphone and speech access are configured separately in Voice. Full Disk Access is not requested.").font(.caption)
            }.id(refresh)
            if let model=AppCoordinator.shared?.model {
                Section("Voice, productivity and private data") {
                    Picker("Local translation model",selection:$translationMode) {
                        Text("Automatic · tested Hindi preset").tag("automatic")
                        Text("Current chat model · quality varies").tag("current")
                        Text("Installed qwen3:8b for both directions").tag("qwen3:8b")
                    }
                    Text("Automatic uses installed qwen3:8b for Hindi and the chat model for English. No model is downloaded automatically. The larger model trades startup time for better translation quality and unloads after use.").font(.caption)
                    Text("Microphone: "+(model.voice.microphoneStatus == .authorized ? "Granted":"Not granted"))
                    Text("Speech recognition: "+(model.voice.speechStatus == .authorized ? "Granted":"Not granted"))
                    Text("Calendar: "+(model.calendar.canRead ? "Granted":"Not granted"))
                    Text("macOS Reminders: "+(model.calendar.canReadReminders ? "Granted":"Not granted"))
                    Text("Contacts: "+(model.contacts.authorized ? "Granted":"Not granted"))
                    Button("Configure voice permissions…"){AppCoordinator.shared?.showVoice()}
                    Button("Configure Calendar, Reminders and Contacts…"){AppCoordinator.shared?.showProductivity()}
                    Text("Online sources are off by default. Enable the online capability above to use Open-Meteo weather, BBC RSS headlines and explicit browser navigation. Only the requested city/search is sent; no assistant history, transcripts or contacts are uploaded.").font(.caption)
                    Button("Stop all microphone activity"){AppCoordinator.shared?.stopVoice()}
                    Text("Recording and wake listening are off until explicitly started. Meeting data and local reminders are encrypted with an app-specific Keychain key. External account writes are off by default.").font(.caption)
                }
            }
            if let model=AppCoordinator.shared?.model {ProactiveSettings(assistant:model.proactive,reminders:model.reminders)}
            ContextSettings()
            RoutineSettings()
            WorkflowSettings()
            Section("Recent actions · metadata only") {
                ForEach(preferences.records) { row in HStack { Text(row.tool); Spacer(); Text(row.success ? "Succeeded" : "Stopped"); Text(row.date, style: .time) }.font(.caption) }
            }
        }.formStyle(.grouped)
    }
}
