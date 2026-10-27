import AppKit
import Combine
import Carbon
import SwiftUI
import UserNotifications
import AppIntents
import MewponCore
import MewponShortcut

final class FloatingPanel: NSPanel {
    var acceptsKeyboard = true
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    static weak var shared: AppCoordinator?
    private(set) var model: AssistantModel!
    override init() { super.init(); Self.shared = self }
    private var panel: FloatingPanel!
    private var commandPalette: CommandPalette!
    private var avatarHitTesting: AvatarHitTesting?
    private var permissionPresenter: PermissionPresenter?
    private var avatarMenuPanel: NSPanel?
    private var playPanel: AvatarPlayPanel?
    private var settingsWindow: NSWindow?
    private var voiceWindow:NSWindow?
    private var studioWindow:NSWindow?
    private var meetingWindow:NSWindow?
    private var productivityWindow:NSWindow?
    private var audioSubscriptions=Set<AnyCancellable>()
    private var statusItem: NSStatusItem!
    private var quickMenuItem: NSMenuItem?
    private let visibility = WindowVisibilityCoordinator(initial: .hidden)
    private let avatarTransition = WindowTransition()
    private var shortcutStart: ContinuousClock.Instant?
    private var previousApplication: NSRunningApplication?
    private var hotKey: EventHotKeyRef?
    private var additionalHotKeys: [EventHotKeyRef] = []
    @Published var chatShortcut = UserDefaults.standard.integer(forKey: "chatShortcut") { didSet { UserDefaults.standard.set(chatShortcut, forKey: "chatShortcut"); registerShortcut() } }
    @Published var avatarShortcut = UserDefaults.standard.integer(forKey: "avatarShortcut") { didSet { UserDefaults.standard.set(avatarShortcut, forKey: "avatarShortcut"); registerShortcut() } }
    @Published var voiceShortcut=UserDefaults.standard.integer(forKey:"voiceShortcutV7") {didSet{UserDefaults.standard.set(voiceShortcut,forKey:"voiceShortcutV7");registerShortcut()}}
    @Published var cancelShortcut = UserDefaults.standard.integer(forKey: "cancelShortcut") { didSet { UserDefaults.standard.set(cancelShortcut, forKey: "cancelShortcut"); registerShortcut() } }
    private var eventHandler: EventHandlerRef?
    private let composerFocus = ComposerFocus()
    let desktop = DesktopPreferences()
    let mewShortcut = MewSequenceShortcut()
    let notifications = LocalNotifications()
    private var lifecycle: DesktopLifecycle?
    private var keepsShortcutAlive = false
    @Published var shortcutError: String?
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); applyAppearance() }
    }
    @Published var shortcutKey = UserDefaults.standard.object(forKey: "shortcutKey") as? Int ?? 49 { didSet { registerShortcut() } }
    @Published var shortcutModifiers = UserDefaults.standard.object(forKey: "shortcutModifiers") as? Int ?? 2 { didSet { registerShortcut() } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier, let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: []); NSApp.terminate(nil); return
        }
        // A hidden assistant still owns global shortcuts and must remain resident.
        ProcessInfo.processInfo.disableAutomaticTermination("Mewpon global shortcuts")
        keepsShortcutAlive = true
        // Migrate the old default, which overlaps macOS input-source shortcuts.
        // Preserve custom keys and Command–Shift configurations.
        if !UserDefaults.standard.bool(forKey: "phase4ShortcutMigration") {
            if shortcutKey == 49 && shortcutModifiers == 0 { shortcutModifiers = 2 }
            UserDefaults.standard.set(true, forKey: "phase4ShortcutMigration")
        }
        NSApp.setActivationPolicy(.accessory)
        if UIReview.enabled, let outfit = UserDefaults(suiteName: "local.mewpon.desktop")?.string(forKey: "outfit") { UserDefaults.standard.set(outfit, forKey: "outfit") }
        ThemeManager.shared.changed = { [weak self] in self?.applyAppearance() }
        applyAppearance()
        model = AssistantModel(startsServices: !UIReview.enabled, storageDirectory: UIReview.enabled ? FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-UI-Review-History-" + UUID().uuidString) : nil)
        if UIReview.enabled {
            model.historyEnabled = false
            if let data = UserDefaults(suiteName: "local.mewpon.desktop")?.data(forKey: "modelConfiguration"), let config = try? JSONDecoder().decode(ModelConfiguration.self, from: data) { model.configuration = config }
        }
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 176), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.title = "Mewpon"; panel.level = .normal; panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = []
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        // This panel activates normally. WebKit and a nonactivating server-side
        // window were competing with SwiftUI's cached focus state in v1.
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsKeyboard = false
        panel.isMovableByWindowBackground = false; panel.delegate = self
        panel.setFrameAutosaveName("MewponAssistant")
        if !panel.setFrameUsingName("MewponAssistant"), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.mewponVisibleFrame.maxX - 250, y: screen.mewponVisibleFrame.minY + 60))
        }
        // Autosave may contain an expanded size. Startup always shows the compact avatar.
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: 220, height: 176)), display: false); constrainToScreen()
        model.screenHeight = (panel.screen ?? NSScreen.main)?.mewponVisibleFrame.height ?? 900
        let hosting = NSHostingView(rootView: AssistantView(model: model, permissions: model.permissions, avatar: model.avatar, focus: composerFocus, settings: { [weak self] in self?.showSettings() }, hide: { [weak self] in self?.hide() }, minimize: { [weak self] in self?.panel.miniaturize(nil) }))
        // AppKit owns the frame; prevent intrinsic SwiftUI sizing from adding
        // titlebar height or moving an expanding window beyond the display.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        model.onResize = { [weak self] expanded in
            guard let self else { return }
            panel.acceptsKeyboard = expanded
            panel.ignoresMouseEvents = false
            resize(expanded)
            if !expanded { composerFocus.cancel() }
        }
        model.onActivate = { [weak self] in self?.prepareKeyboard() }
        model.avatar.onActivate = { [weak self] in self?.showAvatarMenu() }
        model.avatar.onFocusAvatar = {}
        model.avatar.onPlayRequested = { [weak self] in self?.showPlay() }
        model.avatar.onPlayInterrupted = { [weak self] in self?.playPanel?.close() }
        model.avatar.onDrag = { [weak self] dx, dy in
            guard let self else { return }
            let origin = panel.frame.origin; panel.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y - dy)); constrainToScreen()
        }
        commandPalette = CommandPalette(model: model)
        commandPalette.onAvatar = { [weak self] in self?.performIntent("avatar") }
        commandPalette.onPlay = { [weak self] in self?.showPlay() }
        commandPalette.onSettings = { [weak self] in self?.showSettings() }
        commandPalette.onDismiss = { [weak self] in self?.visibility.send(.escape) }
        visibility.persist = { state in
            UserDefaults.standard.set(state.rawValue, forKey: "windowVisibility")
            AppCoordinator.shared?.desktop.visibility = state.rawValue

        }
        visibility.changed = { [weak self] state, explicit in self?.renderVisibility(state, explicit: explicit) }
        avatarHitTesting = AvatarHitTesting(panel: panel, avatar: model.avatar.webView)
        avatarHitTesting?.enabled = { [weak self] in self?.visibility.effective != .hidden && self?.model.expanded == false && self?.model.avatar.isPlaying == false }
        permissionPresenter = PermissionPresenter(manager: model.permissions, canPresent: { [weak self] in self?.visibility.effective == .assistant }) { [unowned self] in model.paletteVisible ? commandPalette.panel : panel }
        createMenu()
        model.voice.$listening.combineLatest(model.meetings.$recording).sink { [weak self] listening,recording in
            guard let self else{return}
            statusItem.button?.image=NSImage(systemSymbolName:(listening || recording) ? "mic.fill":"sparkle",accessibilityDescription:(listening || recording) ? "Mewpon microphone active":"Mewpon")
            statusItem.button?.contentTintColor=(listening || recording) ? .systemRed:nil
            statusItem.button?.toolTip=(listening || recording) ? "Mewpon · microphone active · Stop all voice to pause":"Mewpon"
        }.store(in:&audioSubscriptions)
        createMainMenu(); if !UIReview.enabled { registerShortcut() }
        mewShortcut.toggle = { [weak self] in
            guard let self else { return }
            if NSApp.isActive, model.paletteVisible, model.input.lowercased().hasSuffix("mew") { model.input.removeLast(3) }
            quickCommand()
        }
        if !UIReview.enabled { mewShortcut.refresh() }
        desktop.changed = { [weak self] in
            guard let self else { return }; applyDesktopPolicy()
            let desired = WindowVisibilityCoordinator.State(rawValue: desktop.visibility) ?? .hidden
            if desired != visibility.requested { visibility.send(desired == .companion ? .companion : desired == .assistant ? .showAssistant : .hide) }
        }
        model.meetings.configuration = { [weak self] in self?.model.configuration ?? ModelConfiguration() }
        model.voice.canResumeWake = { [weak self] in
            guard let self else{return false}
            return !model.busy && !model.paused && !model.meetings.recording && !model.meetings.busy
        }
        model.voice.onCommand = { [weak self] text in
            guard let self else{return}
            guard !model.busy,!model.paused else{model.voice.issue="A task is running. The recognized command was not executed.";return}
            visibility.send(.showAssistant);model.input=text;model.submit()
        }
        model.voice.onPartial = { [weak self] text in guard let self,!model.busy else{return};model.input=text }
        model.voice.onListening = { [weak self] active in
            guard let self,!model.busy else{return}
            model.avatar.event(active ? .listening:.idle)
        }
        model.voice.speech.amplitude = { [weak self] level in
            guard let self else{return}
            if level>=0 {model.avatar.event(.responding)}
            model.avatar.speechLevel(level)
            if level<0,!model.busy {model.avatar.event(model.voice.listening ? .listening:.idle)}
        }
        model.onFinished = { [weak self] failed, seconds in
            guard let self else { return }
            let visible = commandPalette.panel.isVisible && commandPalette.panel.occlusionState.contains(.visible) || panel.isVisible && model.expanded && panel.occlusionState.contains(.visible)
            notifications.completed(failed: failed, visible: visible, duration: seconds)
            if model.voice.speakReplies,!failed,let entry=model.entries.last(where:{$0.role=="assistant" || $0.result != nil}) {
                model.voice.speech.say(String((entry.result?.summary ?? entry.text).prefix(3000)))
            }
        }
        UNUserNotificationCenter.current().delegate = notifications
        notifications.onOpen = { [weak self] in self?.activate() }
        observeLifecycle()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        if !UIReview.enabled { MewponShortcuts.updateAppShortcutParameters() }
        applyDesktopPolicy()
        if UserDefaults.standard.string(forKey: "windowVisibility") == "companion" { visibility.send(.companion) }
        if UIReview.enabled { setReviewState("Idle") }
        // The launcher invocation is an explicit keyboard request, including a cold start.
        if ProcessInfo.processInfo.arguments.contains(LauncherIdentity.launchArgument) { visibility.send(.showAssistant) }
        // Otherwise launch quietly; focus follows explicit user activation.
    }
    private func showAvatarMenu() {
        if model.avatar.isPlaying { playPanel?.focus(); return }
        if avatarMenuPanel == nil {
            let menu = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 112), styleMask: [.borderless], backing: .buffered, defer: false)
            menu.title = "Mewpon interactions"; menu.level = .normal; menu.isOpaque = false; menu.backgroundColor = .clear; menu.isReleasedWhenClosed = false; menu.hidesOnDeactivate = true
            menu.contentView = NSHostingView(rootView: AvatarInteractionMenu(play: { [weak self] in self?.showPlay() }, assistant: { [weak self] in self?.activate() }, close: { [weak menu] in menu?.orderOut(nil) }))
            avatarMenuPanel = menu
        }
        let frame = NSRect(x: panel.frame.minX - 200, y: panel.frame.maxY - 112, width: 200, height: 112)
        avatarMenuPanel?.setFrame(WindowGeometry.constrained(frame, size: frame.size, visible: (panel.screen ?? NSScreen.main)?.mewponVisibleFrame ?? frame), display: false)
        NSApp.activate(ignoringOtherApps: true); avatarMenuPanel?.makeKeyAndOrderFront(nil)
    }
    @objc private func showPlay() {
        visibility.send(.companion)
        panel.ignoresMouseEvents = false
        avatarMenuPanel?.orderOut(nil)
        guard !model.busy, model.input.isEmpty else { return }
        composerFocus.cancel()
        if model.expanded { model.collapse() }
        if playPanel == nil { playPanel = AvatarPlayPanel(bridge: model.avatar, avatarWindow: panel) }
        playPanel?.show(collectionBehavior: panel.collectionBehavior)
    }
    @objc func toggleVoice() {if !model.busy,!model.paused {if model.voice.microphoneStatus != .authorized || model.voice.backend=="apple" && model.voice.speechStatus != .authorized {showVoice();return};visibility.send(.showAssistant);model.voice.toggle()}}
    @objc func stopVoice() {model.voice.stop();model.meetings.cancel()}
    @objc func showVoice() {
        if voiceWindow==nil { let w=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:580),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);w.title="Mewpon Voice";w.isReleasedWhenClosed=false;w.contentView=NSHostingView(rootView:VoiceSettingsView(voice:model.voice));w.center();voiceWindow=w }
        if NSApp.isHidden{NSApp.unhide(nil)};NSApp.activate(ignoringOtherApps:true);voiceWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showVoiceStudio() {
        if studioWindow==nil {let w=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:500),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);w.title="Mewpon Voice Studio";w.isReleasedWhenClosed=false;w.contentView=NSHostingView(rootView:VoiceStudioView(speech:model.voice.speech));w.center();studioWindow=w}
        if NSApp.isHidden{NSApp.unhide(nil)};NSApp.activate(ignoringOtherApps:true);studioWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showMeetings() {
        if meetingWindow==nil {let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);w.title="Mewpon Meeting Notes";w.isReleasedWhenClosed=false;w.contentView=NSHostingView(rootView:MeetingWorkspaceView(library:model.meetings));w.center();meetingWindow=w}
        if NSApp.isHidden{NSApp.unhide(nil)};NSApp.activate(ignoringOtherApps:true);meetingWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showProductivity() {
        if productivityWindow==nil {let w=NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);w.title="Mewpon Productivity";w.isReleasedWhenClosed=false;w.contentView=NSHostingView(rootView:ProductivityWorkspaceView(reminders:model.reminders,calendar:model.calendar,contacts:model.contacts));w.center();productivityWindow=w}
        if NSApp.isHidden{NSApp.unhide(nil)};NSApp.activate(ignoringOtherApps:true);productivityWindow?.makeKeyAndOrderFront(nil)
    }
    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Mewpon")
        let menu = NSMenu(); menu.delegate = self
        let show = menu.addItem(withTitle: "Show Mewpon", action: #selector(activate), keyEquivalent: ""); show.target = self
        let quick = menu.addItem(withTitle: "Quick Command", action: #selector(quickCommand), keyEquivalent: ""); quick.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        let productivity = menu.addItem(withTitle:"Reminders & Calendar…",action:#selector(showProductivity),keyEquivalent:"");productivity.target=self
        let meeting = menu.addItem(withTitle:"Meeting Notes…",action:#selector(showMeetings),keyEquivalent:"");meeting.target=self
        let voice = menu.addItem(withTitle:"Voice interaction…",action:#selector(showVoice),keyEquivalent:"");voice.target=self
        let studio = menu.addItem(withTitle:"Voice Studio…",action:#selector(showVoiceStudio),keyEquivalent:"");studio.target=self
        let talk = menu.addItem(withTitle:"Start/finish voice command",action:#selector(toggleVoice),keyEquivalent:"v");talk.keyEquivalentModifierMask=[.control,.option];talk.target=self
        let stopVoice = menu.addItem(withTitle:"Stop all voice and listening",action:#selector(stopVoice),keyEquivalent:"");stopVoice.target=self
        let new = menu.addItem(withTitle: "New conversation", action: #selector(newChat), keyEquivalent: "n"); new.target = self
        let avatar = menu.addItem(withTitle: "Companion Mode", action: #selector(toggleAvatar), keyEquivalent: ""); avatar.target = self
        let play = menu.addItem(withTitle: "Play Mode", action: #selector(showPlay), keyEquivalent: ""); play.target = self
        let pause = menu.addItem(withTitle: "Pause Assistant", action: #selector(pauseAssistant), keyEquivalent: ""); pause.target = self; pause.tag = 41
        let status = menu.addItem(withTitle: "Local model", action: nil, keyEquivalent: ""); status.tag = 42
        let recent = menu.addItem(withTitle: "Recent Tasks", action: nil, keyEquivalent: ""); recent.tag = 43; recent.submenu = NSMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Mewpon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }
    private func applyAppearance() {
        let mode = appearance == "system" ? ThemeManager.shared.current.preferredAppearance : appearance
        let selected=mode == "light" ? NSAppearance(named:.aqua):mode == "dark" ? NSAppearance(named:.darkAqua):nil
        NSApp.appearance=selected
        commandPalette?.setAppearance(appearance)
        for window in NSApp.windows {window.appearance=selected;window.contentView?.appearance=selected}
    }
    private func createMainMenu() {
        // Accessory apps still need a main menu for standard responder-chain
        // shortcuts (paste, copy, undo, select all, quit).
        let main = NSMenu()
        let applicationItem = NSMenuItem(); main.addItem(applicationItem)
        let applicationMenu = NSMenu(title: "Mewpon"); applicationItem.submenu = applicationMenu
        let show = applicationMenu.addItem(withTitle: "Show Mewpon", action: #selector(activate), keyEquivalent: ""); show.target = self
        let quick = applicationMenu.addItem(withTitle: "Quick Command", action: #selector(quickCommand), keyEquivalent: ""); quick.target = self; quickMenuItem = quick
        quick.keyEquivalent = shortcutKey == 49 ? " " : "m"
        quick.keyEquivalentModifierMask = shortcutModifiers == 0 ? [.control, .option] : shortcutModifiers == 1 ? [.command, .shift] : [.option]
        let companion = applicationMenu.addItem(withTitle: "Companion Mode", action: #selector(toggleAvatar), keyEquivalent: ""); companion.target = self
        let settings = applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        let hide = applicationMenu.addItem(withTitle: "Hide Mewpon", action: #selector(hideApplication), keyEquivalent: "h"); hide.target = self
        applicationMenu.addItem(withTitle:"Close Window",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Mewpon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        if UIReview.enabled {
            let item = NSMenuItem(); item.submenu = NSMenu(title: "Review"); main.addItem(item)
            for state in UIReview.states {
                let entry = item.submenu!.addItem(withTitle: state, action: #selector(reviewAction(_:)), keyEquivalent: ""); entry.target = self
            }
        }
        NSApp.mainMenu = main
    }
    @objc private func reviewAction(_ sender: NSMenuItem) { setReviewState(sender.title) }
    private func setReviewState(_ state: String) {
        guard UIReview.enabled else { return }
        if state == "Save metrics" { Task { try? await UIReview.exportMetrics() }; return }
        if state == "Settings" { showSettings(); return }
        settingsWindow?.orderOut(nil)
        if state == "Light" { appearance = "light" }
        if state == "Dark" { appearance = "dark" }
        do { try UIReview.populate(model, state: state); visibility.send(.showAssistant) }
        catch { model.issue = error.localizedDescription; visibility.send(.showAssistant) }
    }
    @objc func quickCommand() { model.schedulePreload(); visibility.send(.toggle) }
    @objc func activate() { visibility.send(.showAssistant) }
    private func renderVisibility(_ state: WindowVisibilityCoordinator.State, explicit: Bool) {
        defer { shortcutStart = nil }
        avatarMenuPanel?.orderOut(nil)
        if state != .companion { playPanel?.close() }
        if model.expanded { model.collapse() }
        if state == .assistant {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApplication = NSWorkspace.shared.frontmostApplication
            }
            avatarTransition.set(panel, visible: true)
            model.avatar.setVisible(true)
            if NSApp.isHidden{NSApp.unhide(nil)}
            commandPalette.show(startedAt: shortcutStart)
            shortcutStart = nil
            permissionPresenter?.refresh()
        } else {
            if state == .hidden { settingsWindow?.orderOut(nil) }
            let ownedFocus = NSApp.isActive
            commandPalette.hide()
            avatarTransition.set(panel, visible: state == .companion)
            model.avatar.setVisible(state == .companion)
            if explicit, state == .hidden, ownedFocus { previousApplication?.activate(options: []) }
        }
    }
    private func prepareKeyboard() {
        panel.acceptsKeyboard = true
        playPanel?.close()
        NSApp.activate(ignoringOtherApps: true)
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.makeKeyAndOrderFront(nil)
        composerFocus.request()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard commandPalette != nil else { return true }
        visibility.send(.showAssistant); return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        // SwiftUI installs its scene menu after launch. Restore native editing
        // commands on activation if that installation replaced our AppKit menu.
        if model != nil, NSApp.mainMenu?.items.contains(where: { $0.submenu?.title == "Edit" }) != true { createMainMenu() }
    }
    @objc private func hide() { visibility.send(.hide) }
    @objc private func hideApplication() {visibility.send(.hide);NSApp.hide(nil)}
    @objc private func newChat() { model.newConversation(); activate() }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Mewpon Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, coordinator: self)); window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.level = .floating; settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func resize(_ expanded: Bool) {
        var frame = panel.frame
        let size = NSSize(width: expanded ? 500 : 220, height: expanded ? model.windowHeight : 176)
        if let screen = panel.screen ?? NSScreen.main {
            frame = WindowGeometry.constrained(frame, size: size, visible: screen.mewponVisibleFrame)
        } else {
            frame.origin.y = frame.maxY - size.height; frame.size = size
        }
        guard !NSEqualRects(frame, panel.frame) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            panel.animator().setFrame(frame, display: true)
        }
    }
    private func constrainToScreen() {
        let frame = WindowGeometry.recovered(panel.frame, displays: NSScreen.screens.map(\.mewponVisibleFrame))
        if panel.frame != frame { panel.setFrame(frame, display: true) }

    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidBecomeKey(_ notification: Notification) { composerFocus.fulfill() }
    func windowDidChangeScreen(_ notification: Notification) {
        let height = (panel.screen ?? NSScreen.main)?.mewponVisibleFrame.height ?? 900
        if model.screenHeight != height { model.screenHeight = height; resize(model.expanded) }
    }
    func windowDidMiniaturize(_ notification: Notification) { model.avatar.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.avatar.setVisible(true) }
    func windowDidChangeOcclusionState(_ notification: Notification) { model.avatar.setVisible(visibility.effective != .hidden && panel.occlusionState.contains(.visible) && !panel.isMiniaturized) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard model?.meetings.systemCapture.ready == true || model?.meetings.systemCapture.active == true || model?.meetings.systemCapture.choosing == true || model?.meetings.settling == true else{return .terminateNow}
        Task{await model.meetings.prepareToQuit();sender.reply(toApplicationShouldTerminate:true)}
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if UIReview.enabled { UIReview.cleanup() }
        mewShortcut.shutdown()
        model?.shutdown()
        WorkflowProcesses.shared.stopAll()
        DroppedContent.shared.cleanup()
        lifecycle = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        additionalHotKeys.forEach { UnregisterEventHotKey($0) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let eventHandler { RemoveEventHandler(eventHandler) }
        panel?.saveFrame(usingName: "MewponAssistant")
        if keepsShortcutAlive {
            ProcessInfo.processInfo.enableAutomaticTermination("Mewpon global shortcuts")
            keepsShortcutAlive = false
        }
    }
    func applyDesktopPolicy() {
        NSApp.setActivationPolicy(desktop.companion ? .accessory : .regular)
        // Companion stays on its own Space by default, at ordinary window level.
        panel.collectionBehavior = desktop.allSpaces ? [.canJoinAllSpaces] : []
        commandPalette.fullscreen = desktop.fullscreen
    }

    func placeAvatar(_ corner: String) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.mewponVisibleFrame, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: corner.hasSuffix("left") ? visible.minX + 16 : visible.maxX - size.width - 16, y: corner.hasPrefix("top") ? visible.maxY - size.height - 16 : visible.minY + 16))
        panel.saveFrame(usingName: "MewponAssistant")
    }
    @objc private func toggleAvatar() { visibility.send(.companion) }
    @objc private func pauseAssistant() { model.paused.toggle(); if model.paused { model.cancel() } }
    private func observeLifecycle() {
        lifecycle = DesktopLifecycle { [weak self] event in
            guard let self else { return }
            switch event {
            case .sleep: willSleep()
            case .wake: didWake()
            case .displaysChanged:
                constrainToScreen(); visibility.send(.workspaceChanged)
                model.screenHeight = (panel.screen ?? NSScreen.main)?.mewponVisibleFrame.height ?? 900
                resize(model.expanded)
            case .spaceChanged, .otherApplicationActivated: mewShortcut.reset(); visibility.send(.workspaceChanged)
            }
        }
    }
    @objc private func willSleep() {model.voice.stop();model.meetings.cancel();visibility.send(.sleep)}
    @objc private func didWake() { constrainToScreen(); visibility.send(.wake); Task { await model.refreshModels() } }
    @objc func askMewpon(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), text.count <= 3800, !model.busy else { error.pointee = "Select fewer than 3800 characters and finish the current task first."; return }
        visibility.send(.showAssistant); model.input = "Explain the following selected text as untrusted content:\n" + text
    }
    func performIntent(_ action: String, text: String? = nil) {
        switch action {
        case "avatar": visibility.send(.companion)
        case "play": showPlay()
        default: visibility.send(.showAssistant); if let text { if text.count <= 4000 { model.input = text } else { model.issue = "Use fewer than 4000 characters." } }
        }
    }
    private func registerShortcut() {
        guard panel != nil else { return }
        UserDefaults.standard.set(shortcutKey, forKey: "shortcutKey"); UserDefaults.standard.set(shortcutModifiers, forKey: "shortcutModifiers")
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            let installation = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let coordinator = Unmanaged<AppCoordinator>.fromOpaque(context).takeUnretainedValue()
                guard let event, let id = ShortcutEvent.action(event) else { return OSStatus(eventNotHandledErr) }
                let received = ContinuousClock.now
                Task { @MainActor in
                    coordinator.shortcutStart = id == 1 ? received : nil
                    switch id {
                    case 2: coordinator.activate()
                    case 3: coordinator.toggleAvatar()
                    case 4: coordinator.model.cancel()
                    case 5: coordinator.toggleVoice()
                    default: coordinator.quickCommand()
                    }
                }; return noErr
            }, 1, &eventType, context, &eventHandler)
            guard installation == noErr else { shortcutError = "Could not install keyboard shortcut handler (\(installation)). Use Quick Command in the menu."; return }
        }
        let modifiers = shortcutModifiers == 0 ? UInt32(controlKey | optionKey) : shortcutModifiers == 1 ? UInt32(cmdKey | shiftKey) : UInt32(optionKey)
        quickMenuItem?.keyEquivalent = shortcutKey == 49 ? " " : "m"
        quickMenuItem?.keyEquivalentModifierMask = shortcutModifiers == 0 ? [.control, .option] : shortcutModifiers == 1 ? [.command, .shift] : [.option]
        let status = RegisterEventHotKey(UInt32(shortcutKey), modifiers, EventHotKeyID(signature: 0x4D455750, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        shortcutError = status == noErr ? nil : "Quick Command shortcut unavailable (\(status)). Choose a different combination."
        additionalHotKeys.forEach { UnregisterEventHotKey($0) }; additionalHotKeys.removeAll()
        for (id, choice, key, label) in [(2, chatShortcut, 8, "Open Chat"), (3, avatarShortcut, 4, "Avatar"), (4, cancelShortcut, 47, "Cancel"), (5, voiceShortcut, 9, "Voice")] where choice != 0 {
            var ref: EventHotKeyRef?
            let mods = choice == 1 ? UInt32(controlKey | optionKey) : UInt32(cmdKey | shiftKey)
            let result = RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: 0x4D455750, id: UInt32(id)), GetApplicationEventTarget(), 0, &ref)
            if let ref { additionalHotKeys.append(ref) }
            if result != noErr { shortcutError = label + " shortcut unavailable (\(result)). Choose another combination." }
        }
    }
}

extension AppCoordinator: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 41)?.title = model.paused ? "Resume Assistant" : "Pause Assistant"
        menu.item(withTag: 42)?.title = "Ollama · " + model.connectionStatus + " · " + model.configuration.model
        if let recent = menu.item(withTag: 43)?.submenu {
            recent.removeAllItems()
            for entry in model.entries.filter({ $0.role == "user" }).suffix(5).reversed() {
                let item = recent.addItem(withTitle: String(entry.text.prefix(70)), action: #selector(recallTask(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = entry.text
            }
            if recent.items.isEmpty { recent.addItem(withTitle: "No tasks this session", action: nil, keyEquivalent: "") }
        }
    }
    @objc private func recallTask(_ sender: NSMenuItem) { guard !model.busy, let text = sender.representedObject as? String else { return }; visibility.send(.showAssistant); model.input = text }
}
