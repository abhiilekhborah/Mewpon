import AppKit
import SwiftUI
import MewponShortcut

typealias MewSequenceRecognizer = MewponShortcut.MewSequenceRecognizer

@MainActor final class MewSequenceShortcut: ObservableObject {
    @Published var enabled = UserDefaults.standard.object(forKey: "mewSequenceEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "mewSequenceEnabled"); refresh() }
    }
    @Published private(set) var status = "Not checked"
    let launcher = BackgroundShortcutLauncher()
    var toggle: (() -> Void)?
    private let listener = MewSequenceListener()
    init() {
        listener.statusChanged = { [weak self] in self?.status = $0 }
        listener.toggle = { [weak self] in self?.toggle?() }
    }
    func reset() { listener.reset() }
    func refresh() { listener.refresh(enabled: enabled); launcher.refresh() }
    func requestAccess() { listener.requestAccess(); if !enabled { listener.shutdown() } }
    func openPermissionSettings() { listener.openPermissionSettings() }
    func receive(_ type: CGEventType, _ event: CGEvent) { listener.receive(type, event) }
    func shutdown() { listener.shutdown() }
}

struct MewSequenceSettings: View {
    @ObservedObject var shortcut: MewSequenceShortcut
    var body: some View {
        Toggle("Type mew, then press Command · show/hide", isOn: $shortcut.enabled)
        Text(shortcut.status).font(.caption).foregroundStyle(.secondary)
        BackgroundShortcutSettings(launcher: shortcut.launcher)
        DisclosureGroup("Keyboard access and details") {
        HStack { Button("Enable keyboard access…") { shortcut.requestAccess() }; Button("Input Monitoring settings") { shortcut.openPermissionSettings() }; Button("Refresh shortcut") { shortcut.refresh() } }
        Text("Type m, e, w in order, then press Command within 1.5 seconds. The letters stay in the current app. Only the matching prefix is kept in memory; keystrokes are never saved or sent to the model. Secure Input blocks this shortcut. Option–Space remains available. Enable “Open Mewpon after quitting” to keep a separate launcher available when the main app is closed. The launcher needs its own Input Monitoring approval.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
