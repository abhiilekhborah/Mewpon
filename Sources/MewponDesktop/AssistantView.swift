import SwiftUI
import MewponCore

struct SettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var systemScheme
    @ObservedObject var model: AssistantModel
    @ObservedObject var coordinator: AppCoordinator
    @State private var section="General"
    @State private var outfit = UserDefaults.standard.string(forKey: "outfit") ?? "default"
    @State private var expression = "neutral"
    @State private var activity = "working"
    @State private var animation = "bounce"
    @AppStorage("solidSurfaces") private var solidSurfaces = false
    @AppStorage("paletteWidth") private var paletteWidth = 600.0
    var body: some View {
        VStack(spacing:0) {
            Picker("Settings",selection:$section) {
                ForEach(["General","Appearance","Avatar","AI","Permissions","Privacy"],id:\.self){Text($0).tag($0)}
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal,20).padding(.vertical,14)
            Group {
                switch section {
                case "Appearance":appearance
                case "Avatar":mascot
                case "AI":ai
                case "Permissions":AutomationSettings(preferences: model.automation)
                case "Privacy":privacy
                default:general
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(width:640,height:560)
        .tint(Color(nsColor: ThemePalette.native(theme.current.palette(dark: theme.scheme(appearance: coordinator.appearance, system: systemScheme) == .dark).accent)))
        .preferredColorScheme(theme.preferredScheme(appearance: coordinator.appearance))
    }
    private var general: some View {
        Form {
            Section("Activation") {
                MewSequenceSettings(shortcut: coordinator.mewShortcut)
                DisclosureGroup("Additional shortcuts") {
                Picker("Shortcut key", selection: $coordinator.shortcutKey) { Text("Space").tag(49); Text("M").tag(46) }
                Picker("Shortcut modifiers", selection: $coordinator.shortcutModifiers) { Text("Option").tag(2); Text("Control + Option").tag(0); Text("Command + Shift").tag(1) }
                ForEach(["chat", "avatar", "cancel"], id: \.self) { action in
                    Picker(action == "chat" ? "Open Chat · C" : action == "avatar" ? "Show/Hide Avatar · H" : "Cancel Task · Period", selection: action == "chat" ? $coordinator.chatShortcut : action == "avatar" ? $coordinator.avatarShortcut : $coordinator.cancelShortcut) {
                        Text("Disabled").tag(0); Text("Control + Option").tag(1); Text("Command + Shift").tag(2)
                    }
                }
                Picker("Start/finish voice command · V",selection:$coordinator.voiceShortcut){Text("Disabled").tag(0);Text("Control + Option").tag(1);Text("Command + Shift").tag(2)}
                if let error = coordinator.shortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                Text("Use the menu bar icon to restore a hidden or minimized Mewpon. Drag the avatar or panel to move it.").font(.caption).foregroundStyle(.secondary)

            }
            DesktopIntegrationSettings(preferences: coordinator.desktop, notifications: coordinator.notifications, place: coordinator.placeAvatar)
        }.formStyle(.grouped)
    }
    private var appearance: some View {
        Form {
            ThemeGallery()
            Section("Interface") {
                Picker("Appearance", selection: $coordinator.appearance) { Text("Theme default").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                Toggle("Use solid surfaces", isOn: $solidSurfaces)
                Picker("Command width", selection: $paletteWidth) { Text("Compact").tag(560.0); Text("Standard").tag(600.0); Text("Comfortable").tag(640.0) }
                Text("The command bar expands only when content needs space. System Reduce Motion, Reduce Transparency, and contrast preferences are respected.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var mascot: some View {
        Form {
            Section("Mascot") {
                Picker("Outfit", selection: $outfit) { ForEach(AvatarMapping.outfits, id: \.self) { Text($0.capitalized).tag($0) } }.onChange(of: outfit) { _, value in model.avatar.setOutfit(value) }
                HStack { Picker("Expression", selection: $expression) { ForEach(AvatarMapping.expressions, id: \.self) { Text($0).tag($0) } }; Button("Preview") { model.avatar.setExpression(expression) } }
                HStack { Picker("Activity", selection: $activity) { ForEach(AvatarMapping.activities, id: \.self) { Text($0).tag($0) } }; Button("Preview") { model.avatar.setActivity(activity) } }
                HStack { Picker("Animation", selection: $animation) { ForEach(AvatarMapping.animations, id: \.self) { Text($0).tag($0) } }; Button("Play") { model.avatar.playAnimation(animation) } }
                Button("Return to idle") { model.avatar.event(.idle) }
                AvatarMetricsView(avatar: model.avatar)
                Text("Choose an outfit, preview an expression, or try an activity. Play Mode is available from the mascot menu.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)

        }.formStyle(.grouped)
    }
    private var ai: some View {
        Form {
            Section("Local model") {
                TextField("Model", text: $model.configuration.model)
                if !model.models.isEmpty {
                    Picker("Installed models", selection: $model.configuration.model) {
                        ForEach(model.models) { m in Text(m.name).tag(m.name) }
                        if !model.models.contains(where: { $0.name == model.configuration.model }) { Text(model.configuration.model + " (missing)").tag(model.configuration.model) }
                    }
                }
                DisclosureGroup("Generation settings") {
                Slider(value: $model.configuration.temperature, in: 0...2, step: 0.1) { Text("Temperature \(model.configuration.temperature, specifier: "%.1f")") }
                Stepper("Context: \(model.configuration.contextWindow)", value: $model.configuration.contextWindow, in: 2048...8192, step: 1024)
                Stepper("Max response: \(model.configuration.maximumTokens) tokens", value: $model.configuration.maximumTokens, in: 64...2048, step: 64)
                Stepper("Timeout: \(Int(model.configuration.timeout)) seconds", value: $model.configuration.timeout, in: 5...300, step: 5)
                Stepper("Keep model warm: \(model.configuration.keepAliveSeconds) seconds", value: $model.configuration.keepAliveSeconds, in: 0...900, step: 60)
                Picker("Thinking",selection:$model.configuration.thinking){Text("Automatic").tag(ModelConfiguration.Thinking.automatic);Text("Off").tag(ModelConfiguration.Thinking.disabled);Text("On when supported").tag(ModelConfiguration.Thinking.enabled)}
                }
                HStack { Button("Refresh models") { Task { await model.refreshModels() } }; Text(model.status).font(.caption).foregroundStyle(.secondary) }
                Text("Start Ollama, then install your chosen model in Terminal. Mewpon never downloads models automatically.").font(.caption).foregroundStyle(.secondary)
                Text("ollama pull " + model.configuration.model).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copy install command") {
                    guard (try? model.configuration.validated()) != nil else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("ollama pull " + model.configuration.model, forType: .string)
                }
            }.disabled(model.busy)
            Section("Performance") {
                Toggle("Execute trusted actions without extra prompts", isOn: $model.directActions)
                Text("Uses the capability rules in Permissions. Context reads and custom program execution still require review; macOS permission prompts remain in force.").font(.caption).foregroundStyle(.secondary)
                Toggle("Keep the selected local model ready while Mewpon runs", isOn: $model.preloadEnabled)
                HStack { Text(model.preloadStatus).font(.caption); Button("Warm up now") { model.schedulePreload(force: true) } }.disabled(model.busy)
                Toggle("Prioritize inference",isOn:$model.configuration.adaptiveAvatar).disabled(model.busy)
                Text("Use 30 fps for the avatar during model requests, then restore 60 fps. Artwork resolution stays the same.").font(.caption).foregroundStyle(.secondary)
                Button("Save performance metrics…") {model.savePerformanceReport()}
                Text("Local timing samples exclude command contents and file paths. Display painting and OS launch completion are separate from routing.").font(.caption).foregroundStyle(.secondary)
            }

        }.formStyle(.grouped)
    }
    private var privacy: some View {
        Form {
            Section("Privacy and history") {
                Toggle("Save conversation on this Mac", isOn: Binding(get: { model.historyEnabled }, set: { model.setHistory($0) }))
                Button("Clear conversation history") { model.newConversation() }.disabled(model.busy)
                Text("History is off by default. Disabling it deletes the saved conversation; the current session stays in memory. The local action log stores only tool names, times, and success/failure. Explicit native app/file commands can run directly when enabled in Performance; sensitive and model-selected actions still require approval.").font(.caption).foregroundStyle(.secondary)
            }

            Section("File search") { SearchIndexSettings() }
        }.formStyle(.grouped)
    }
}

private struct AvatarMetricsView: View {
    @ObservedObject var avatar: AvatarBridge
    var body: some View {
        HStack {
            Button("Measure renderer") { Task { await avatar.measureRenderer() } }
            if let summary = avatar.performanceSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
