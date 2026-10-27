import AppKit
import SwiftUI
import MewponCore

@MainActor final class PaletteAppearance:ObservableObject {
    @Published var value=UserDefaults.standard.string(forKey:"appearance") ?? "system"
}

/// Separate input window: showing the launcher never moves the companion.
@MainActor final class CommandPalette: NSObject, NSWindowDelegate {
    let panel: FloatingPanel
    let focus = ComposerFocus()
    let appearance=PaletteAppearance()
    private let model: AssistantModel
    private var activationStart: ContinuousClock.Instant?
    var fullscreen = false
    var onDismiss: (() -> Void)?
    var onSettings: (() -> Void)?
    var onAvatar: (() -> Void)?
    var onPlay: (() -> Void)?
    private var requestedHeight: CGFloat = 80
    private var preferredFrame: NSRect?
    private let transition = WindowTransition()
    init(model: AssistantModel) {
        self.model = model
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80), styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        super.init()
        focus.onFulfilled = { [weak self] in
            guard let self, let start = activationStart else { return }; activationStart = nil
            let milliseconds = elapsedMilliseconds(since: start)
            Task { await PerformanceProfiler.shared.record("launcher.first_responder", milliseconds: milliseconds) }
        }
        panel.title = "Mewpon Quick Command"; panel.titleVisibility = .hidden
        panel.isMovable = true; panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: 520, height: 80)
        panel.contentMaxSize = NSSize(width: 760, height: 620)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.setFrameAutosaveName("MewponCommandV3")
        if panel.setFrameUsingName("MewponCommandV3") { preferredFrame = panel.frame }
        panel.titlebarAppearsTransparent = true; panel.titlebarSeparatorStyle = .none
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .normal; panel.isFloatingPanel = false; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false; panel.delegate = self
        let host = NSHostingView(rootView: CommandPaletteView(model: model, permissions: model.permissions, focus: focus, appearance:appearance, dismiss: { [weak self] in self?.onDismiss?() }, settings: { [weak self] in self?.onSettings?() }, moved: { [weak self] in self?.rememberFrame() }, resized: { [weak self] height in self?.updateHeight(height) }, avatar: { [weak self] in self?.onAvatar?() }, play: { [weak self] in self?.onPlay?() }))
        host.sizingOptions = []; panel.contentView = host

    }
    nonisolated static func placement(size: NSSize, visible: NSRect) -> NSRect {
        let size = NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        return NSRect(x: visible.midX - size.width / 2, y: max(visible.minY, visible.maxY - size.height - 70), width: size.width, height: size.height)
    }
    func show(startedAt shortcutStart: ContinuousClock.Instant? = nil) {
        WindowControlSource.remember()
        ContextAccess.shared.rememberSource()
        let start = ContinuousClock.now; activationStart = start
        // Pointer display is deterministic even when the previous key window belongs to another app.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        var target = panel.frame
        if let screen {
            let visible = screen.mewponVisibleFrame
            if panel.isVisible {
                target = WindowGeometry.constrained(panel.frame, size: NSSize(width: preferredWidth, height: requestedHeight), visible: (panel.screen ?? screen).mewponVisibleFrame)
            } else if let saved = preferredFrame, saved.intersects(screen.frame) {
                target = WindowGeometry.constrained(saved, size: NSSize(width: preferredWidth, height: requestedHeight), visible: visible)
            } else {
                let size = NSSize(width: min(preferredWidth, visible.width), height: min(requestedHeight, visible.height))
                target = Self.placement(size: size, visible: visible)
            }
        }
        panel.collectionBehavior = fullscreen ? [.moveToActiveSpace, .fullScreenAuxiliary] : [.moveToActiveSpace]
        // Explicitly summoned assistant stays visible over ordinary app windows.
        // It does not join full-screen Spaces unless the user enables that policy.
        panel.level = .floating
        model.paletteVisible = true
        transition.set(panel, visible: true, frame: target) { [self] in
            NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); focus.request()
        }
        Task {
            await PerformanceProfiler.shared.record("launcher.window_visible", since: start)
            if let shortcutStart { await PerformanceProfiler.shared.record("shortcut.dispatch_to_window_visible", since: shortcutStart) }
        }
        Task { await PerformanceProfiler.shared.record("launcher.activation_assignment", since: start) }
    }
    func setAppearance(_ value:String){appearance.value=value}
    func hide() { if model.paletteVisible { model.permissions.resolve(false) }; model.paletteVisible = false; activationStart = nil; focus.cancel(); transition.set(panel, visible: false) }
    private var preferredWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "paletteWidth")
        return (560...640).contains(saved) ? saved : MewponDesign.commandWidth
    }
    private func updateHeight(_ proposed: CGFloat) {
        let presentation=PalettePresentation.resolve(input:model.input,entries:model.entries,busy:model.busy)
        let height:CGFloat
        if case .files = presentation {height=max(proposed,presentation.height)} else {height=proposed}
        requestedHeight = height
        // AppKit also marks programmatic frame animations as live resizing.
        // Only defer while the user is actually holding a resize gesture.
        guard panel.isVisible, !(panel.inLiveResize && NSEvent.pressedMouseButtons != 0) else{return}
        let visible = (panel.screen ?? NSScreen.main)?.mewponVisibleFrame ?? panel.frame
        let target = WindowGeometry.constrained(panel.frame, size: NSSize(width: preferredWidth, height: height), visible: visible)
        guard target != panel.frame else { return }
        let start = ContinuousClock.now
        transition.resize(panel, frame: target)
        Task { await PerformanceProfiler.shared.record("ui.panel_layout_assignment", since: start) }
    }
    private func rememberFrame() { preferredFrame = panel.frame; panel.saveFrame(usingName: "MewponCommandV3") }
    func windowDidEndLiveResize(_ notification: Notification) {rememberFrame();updateHeight(requestedHeight)}
    func windowDidBecomeKey(_ notification: Notification) { focus.fulfill() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onDismiss?(); return false }
}

struct CommandPaletteView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject var model: AssistantModel
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var focus: ComposerFocus
    @ObservedObject var appearance:PaletteAppearance
    let dismiss: () -> Void
    var settings: () -> Void = {}
    var moved: () -> Void = {}
    var resized: (CGFloat) -> Void = { _ in }
    var avatar: () -> Void = {}
    var play: () -> Void = {}
    @ObservedObject private var contextAccess = ContextAccess.shared
    @ObservedObject private var screenContext = ScreenContext.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("paletteWidth") private var paletteWidth = 600.0
    @State private var inputHeight: CGFloat = 48
    @State private var selection = 0
    @State private var filter = ""
    @State private var showHistory = false
    @State private var followingOutput = true
    @State private var interacting = false
    private var turn: [ChatEntry] { PalettePresentation.currentTurn(model.entries) }
    private var result: ToolResult? { turn.last(where: { $0.result != nil })?.result }
    private var fileResult: ToolResult? { turn.last(where: { $0.result != nil })?.result }
    private var files: [ResultItem] {
        let values = fileResult?.items ?? []
        return filter.isEmpty ? values : values.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.path.localizedCaseInsensitiveContains(filter) }
    }
    private var suggestions: [String] { model.busy ? [] : PalettePresentation.suggestions(for: model.input) }
    private var presentation: PalettePresentation { PalettePresentation.resolve(input: model.input, entries: model.entries, busy: model.busy, history: showHistory) }
    private var transcript: [ChatEntry] { PaletteTranscript.entries(showHistory ? model.entries : turn) }
    private var resolvedScheme:ColorScheme {theme.scheme(appearance: appearance.value, system: scheme)}
    private var tokens:ThemePalette {theme.current.palette(dark: resolvedScheme == .dark)}
    private var layoutHeight: CGFloat { max(permissions.pending == nil ? 80 : 350, presentation.height + max(0, min(96, inputHeight) - 48) + (model.issue == nil ? 0 : 38) + (model.droppedText == nil ? 0 : 32)) }
    private func navigate(_ key: UInt16) -> Bool {
        let count = suggestions.isEmpty ? files.count : suggestions.count
        guard count > 0 else { return false }
        if key == 125 { selection = (selection + 1) % count; return true }
        if key == 126 { selection = (selection + count - 1) % count; return true }
        if key == 48, !suggestions.isEmpty { model.input = suggestions[min(selection, count - 1)]; selection = 0; return true }
        return false
    }
    private func execute() {
        guard !model.paused else{return}
        if model.input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!files.isEmpty,model.canOpenResults {
            model.openResult(files[min(selection,files.count-1)])
        } else if !model.busy {showHistory=false;followingOutput=true;model.submit()}
    }
    var body: some View {
        VStack(spacing: 0) {
            composer
            if model.droppedText != nil { droppedActions }
            if presentation.expanded {
                Divider().padding(.horizontal, 14)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(tokens.color(tokens.surface))
                footer
            }
            if let issue = model.issue { Text(issue).font(MewponDesign.secondary).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 10) }
        }.foregroundStyle(tokens.color(tokens.text))
        .tint(tokens.color(tokens.accent)).accentColor(tokens.color(tokens.accent))
        .background(theme.current.glass ? tokens.color(tokens.background).opacity(resolvedScheme == .light ? 0.82:0.08):tokens.color(tokens.background))
        .environment(\.colorScheme,resolvedScheme)
        .companionGlass(radius: theme.current.radius).clipShape(RoundedRectangle(cornerRadius: theme.current.radius)).padding(8).ignoresSafeArea()
        .preferredColorScheme(theme.preferredScheme(appearance: appearance.value))
        .onAppear { resized(layoutHeight) }
        .onChange(of: layoutHeight) { _, value in resized(value) }
        .onChange(of: paletteWidth) { _, _ in resized(layoutHeight) }
        .onChange(of: model.entries.last(where: { $0.role == "user" })?.id) { _, _ in filter = ""; selection = 0; followingOutput = true }
        .onChange(of: filter) { _, _ in selection = 0 }
        .onDrop(of: [.fileURL, .utf8PlainText, .url, .image], isTargeted: nil) { model.acceptDrop($0) }
    }
    private var composer: some View {
        HStack(spacing: 8) {
            ZStack { WindowDragRegion(finished: moved); Image(systemName: "line.3.horizontal").font(.system(size: 9)).rotationEffect(.degrees(90)).foregroundStyle(.tertiary).allowsHitTesting(false) }.frame(width: 12, height: 42).help("Drag to move Mewpon")
            Menu {
                Button("Show companion", action: avatar)
                Button("Play with Mewpon", action: play)
            } label: { MascotMark().frame(width: 26, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Mewpon companion and Play Mode")
            CommandComposer(text: $model.input, height: $inputHeight, focus: focus, ready: model.ready && !model.paused, submit: execute, escape: dismiss, changed: { selection = 0; model.typing() }, navigate: navigate, placeholderColor: ThemePalette.native(tokens.secondary), textColor: ThemePalette.native(tokens.text), accentColor: ThemePalette.native(tokens.accent), monospace: theme.current.monospace)
            .frame(height: max(48, min(96, inputHeight)))
            VoiceCommandButton(voice:model.voice).disabled((model.busy || model.paused) && !model.voice.listening)
            if model.busy {
                Button { model.cancel() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 18)).foregroundStyle(.primary) }.buttonStyle(.plain).help("Cancel response").accessibilityLabel("Cancel response")
            } else {
                Button(action: execute) { Image(systemName: "return").font(.system(size: 13)).foregroundStyle(model.input.isEmpty && files.isEmpty ? .tertiary : .secondary) }.buttonStyle(.plain).disabled(model.paused || model.input.isEmpty && files.isEmpty).help("Run · Return")
            }
            Menu {
                Button("New conversation") { model.newConversation(); showHistory = false; focus.request() }.disabled(model.busy)
                Button(showHistory ? "Current task" : "Conversation history") { showHistory.toggle() }.disabled(model.entries.isEmpty)
                Divider()
                Button("Attach file or folder…") { model.chooseAttachment() }.disabled(model.busy)
                contextActions
                Divider()
                Button("Voice interaction…"){AppCoordinator.shared?.showVoice()}
                Button("Meeting Notes…"){AppCoordinator.shared?.showMeetings()}
                Button("Voice Studio…"){AppCoordinator.shared?.showVoiceStudio()}
                Button("Settings…", action: settings)
                Button("Hide Mewpon", action: dismiss)
            } label: { Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 24, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More actions")
        }.padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 8)
    }
    @ViewBuilder private var content: some View {
        switch presentation {
        case .idle: EmptyView()
        case .suggestions:
            VStack(spacing: 1) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, command in
                    Button { model.input = command; execute() } label: {
                        HStack(spacing: 12) { Image(systemName: command.hasPrefix("Open") ? "arrow.up.forward.app" : "magnifyingglass").foregroundStyle(.secondary).frame(width: 20); Text(command); Spacer(); if selection == index { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) } }.padding(.horizontal, 12).frame(height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.system(size: 13)).background(selection == index ? MewponDesign.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6)).onHover { if $0 { selection = index } }
                }
            }.padding(8)
        case .files: fileList
        case .working:
            HStack(spacing: 9) { ProgressView().controlSize(.small); Text(model.status).font(MewponDesign.secondary).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 18).padding(.vertical, 12)
        case .confirmation:
            if let result {
                HStack(alignment: .top, spacing: 9) { Image(systemName: result.success ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(result.success ? MewponDesign.accent : .orange); Text(result.summary).font(.system(size: 13)).textSelection(.enabled).lineLimit(3); Spacer(minLength: 0) }.padding(18)
            }
        case .response: response
        }
    }
    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(fileResult?.items.count ?? 0) files\(fileResult?.partial == true ? " shown" : "")").font(.system(size: 12, weight: .medium))
                Spacer()
                TextField("Filter results", text: $filter).textFieldStyle(.plain).font(.system(size: 12)).frame(maxWidth: 180)
                    .onSubmit { if files.indices.contains(selection), model.canOpenResults { model.openResult(files[selection]) } }
                    .onKeyPress(.downArrow) { _ = navigate(125); return .handled }
                    .onKeyPress(.upArrow) { _ = navigate(126); return .handled }
            }.padding(.horizontal, 18).padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(files.enumerated()), id: \.element.id) { index, item in
                            PaletteFileRow(item: item, selected: selection == index, model: model, select: { selection = index }).id(item.id)
                        }
                        if files.isEmpty { Text("No matches in these results").font(MewponDesign.secondary).foregroundStyle(.secondary).padding(20) }
                    }.padding(.horizontal, 8).padding(.bottom, 6)
                }.onChange(of: selection) { _, index in if files.indices.contains(index) { proxy.scrollTo(files[index].id, anchor: .center) } }
            }
            if fileResult?.partial == true { Text("Showing a limited set. Refine your search to narrow it down.").font(MewponDesign.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8) }
        }
    }
    private var response: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(transcript) { entry in
                        if entry.role == "user" { Text(entry.text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).textSelection(.enabled) }
                        else if let result = entry.result { Text(result.summary).font(MewponDesign.secondary).foregroundStyle(.secondary).textSelection(.enabled) }
                        else { MarkdownMessage(text: entry.text).equatable() }
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.modifier(TranscriptTracking(follow: $followingOutput, interacting: $interacting))
                .onChange(of: model.entries.last?.text) { _, _ in if followingOutput && !interacting { proxy.scrollTo("latest", anchor: .bottom) } }
                .overlay(alignment: .bottomTrailing) {
                    if !followingOutput, model.busy { Button("Latest") { followingOutput = true; proxy.scrollTo("latest", anchor: .bottom) }.font(MewponDesign.caption).buttonStyle(.bordered).padding(10) }
                }
        }
    }
    private var footer: some View {
        HStack(spacing: 6) {
            if screenContext.active { Label("One-shot screen OCR", systemImage: "record.circle").foregroundStyle(.orange) }
            else if contextAccess.inspecting { Label("Reading approved context", systemImage: "eye").foregroundStyle(.orange) }
            else { Text(model.paused ? "Paused" : "On this Mac") }
            Spacer()
            if case .files = presentation { Text("↑↓ select   ↵ open") }
            else if case .suggestions = presentation { Text("↑↓ select   ⇥ complete") }
            else { Text("Esc to hide") }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 28)
    }
    private var droppedActions: some View {
        HStack { Text("Selected text").font(MewponDesign.caption).foregroundStyle(.secondary); Button("Explain") { model.useDroppedText("Explain") }; Button("Summarize") { model.useDroppedText("Summarize") }; Button("Rewrite") { model.useDroppedText("Rewrite") }; Spacer() }.font(MewponDesign.secondary).buttonStyle(.plain).padding(.horizontal, 18).padding(.bottom, 10).disabled(model.busy)
    }
    @ViewBuilder private var contextActions: some View {
        Menu("Use context") {
            Button("Selected text") { model.runDirect(ToolCall(name: "read_context", arguments: ["kind": .string("selectedText")])) }
            Button("Browser page") { model.runDirect(ToolCall(name: "read_context", arguments: ["kind": .string("browserPage")])) }
            Button("Finder selection") { model.runDirect(ToolCall(name: "read_context", arguments: ["kind": .string("finderSelection")])) }
            Button("Source window") { model.runDirect(ToolCall(name: "read_context", arguments: ["kind": .string("window")])) }
            Button("Clipboard") { model.runDirect(ToolCall(name: "read_context", arguments: ["kind": .string("clipboard")])) }
            Button("Read screen text…") { model.runDirect(ToolCall(name: "read_screen_text", arguments: [:])) }
        }.disabled(model.busy)
    }
}

private struct MascotMark: View {
    private static let icon: NSImage? = {
        guard let url=Bundle.main.url(forResource:"Mewpon",withExtension:"icns"),let source=NSImage(contentsOf:url),let icon=source.copy() as? NSImage else{return nil}
        // AppKit menus use the NSImage point size, ignoring SwiftUI resizable().
        icon.size=NSSize(width:26,height:26)
        return icon
    }()
    var body: some View {
        if let icon = Self.icon { Image(nsImage: icon).resizable().interpolation(.none).scaledToFit() }
        else { Image(systemName: "sparkle").font(.system(size: 21)).foregroundStyle(MewponDesign.accent) }
    }
}

private struct PaletteFileRow: View {
    let item: ResultItem
    let selected: Bool
    @ObservedObject var model: AssistantModel
    let select: () -> Void
    @State private var hovered = false
    private var location: String {
        let folder = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        return folder.hasPrefix(NSHomeDirectory() + "/") ? "~" + folder.dropFirst(NSHomeDirectory().count) : folder
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) { Text(location).lineLimit(1).truncationMode(.middle); if !item.kind.isEmpty { Text(item.kind.uppercased()).fixedSize() }; if let modified = item.modifiedAt { Text(modified, style: .date).fixedSize() } }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if selected || hovered {
                Button("Open") { model.openResult(item) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(MewponDesign.accent)
                Menu {
                    Button("Reveal in Finder") { model.fileAction(item, action: "reveal") }
                    Button("Quick Look") { model.fileAction(item, action: "preview") }
                    Button("Remember as my CV") { Task { do {try await AuthorizedSearch.shared.remember(item,alias:"resume cv curriculum vitae")} catch {model.issue=error.localizedDescription} } }
                    Button("Read text locally…") { model.runDirect(ToolCall(name: "read_document", arguments: ["path": .string(item.path)])) }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }.padding(.horizontal, 10).frame(height: 52).contentShape(Rectangle())
            .background(selected ? MewponDesign.accent.opacity(0.14) : hovered ? .primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }.onTapGesture(count: 2) { if model.canOpenResults { model.openResult(item) } }.onTapGesture(perform: select).help(item.path).disabled(!model.canOpenResults)
    }
}
