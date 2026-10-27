import AppKit
import Combine
import SwiftUI
import MewponCore

struct AvatarInteractionMenu: View {
    let play: () -> Void
    let assistant: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(spacing: 9) {
            Button(action: play) { Label("Play with Mewpon", systemImage: "gamecontroller").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(Color(red: 0.28, green: 0.54, blue: 0.72))
            Button(action: assistant) { Label("Open assistant", systemImage: "text.bubble").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
        }.font(.system(size: 12, weight: .medium, design: .rounded)).padding(15)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(4).onExitCommand(perform: close)
    }
}

/// A separate pet surface. The conversation view and editor remain untouched.
@MainActor final class AvatarPlayPanel: NSObject, NSWindowDelegate {
    private let bridge: AvatarBridge
    private let panel: NSPanel
    private var monitors: [Any] = []
    private var followToken: AnyCancellable?
    private weak var avatarWindow: NSWindow?
    private var lastPointerTime: TimeInterval = 0
    init(bridge: AvatarBridge, avatarWindow: NSWindow) {
        self.bridge = bridge; self.avatarWindow = avatarWindow
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 306, height: 440), styleMask: [.titled, .fullSizeContentView, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Mewpon Play"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.isReleasedWhenClosed = false; panel.level = .normal; panel.isFloatingPanel = false; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = []; panel.delegate = self
        let host = NSHostingView(rootView: AvatarPlayView(bridge: bridge, close: { [weak self] in self?.close() }))
        host.sizingOptions = []; panel.contentView = host
        followToken = bridge.$followingCursor.removeDuplicates().sink { [weak self] enabled in self?.monitorCursor(enabled) }
    }
    func show(collectionBehavior: NSWindow.CollectionBehavior) {
        panel.collectionBehavior = collectionBehavior
        guard let avatarWindow else { return }
        let visible = (avatarWindow.screen ?? NSScreen.main)?.visibleFrame ?? avatarWindow.frame
        let preferred = NSRect(x: avatarWindow.frame.minX - 316, y: avatarWindow.frame.maxY - 440, width: 306, height: 440)
        panel.setFrame(WindowGeometry.constrained(preferred, size: preferred.size, visible: visible), display: false)
        bridge.enterPlayMode(); NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }
    func close() { monitorCursor(false); panel.orderOut(nil); if bridge.isPlaying { bridge.exitPlayMode() } }
    func focus() { panel.makeKeyAndOrderFront(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    private func monitorCursor(_ enabled: Bool) {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        guard enabled else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in Task { @MainActor in self?.pointerMoved() } }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in self?.pointerMoved(); return event }) { monitors.append(local) }
    }
    private func pointerMoved() {
        guard bridge.isPlaying, bridge.followingCursor, let avatarWindow, avatarWindow.isVisible, !avatarWindow.isMiniaturized else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerTime > 1 / 24 else { return }; lastPointerTime = now
        let mouse = NSEvent.mouseLocation, frame = avatarWindow.frame
        let dx = mouse.x - frame.midX, dy = mouse.y - (frame.maxY - 85)
        bridge.gaze(x: dx / 180, y: -dy / 180)
        guard hypot(dx, dy) > 170, let screen = avatarWindow.screen else { return }
        var next = frame
        next.origin.x += min(2, max(-2, dx * 0.008)); next.origin.y += min(1.5, max(-1.5, dy * 0.008))
        avatarWindow.setFrame(WindowGeometry.constrained(next, size: frame.size, visible: screen.visibleFrame), display: false)
    }
}

private struct PetChoice: Identifiable {
    let id: String; let title: String; let icon: String
}

struct AvatarPlayView: View {
    @ObservedObject var bridge: AvatarBridge
    let close: () -> Void
    @State private var page = "Play together"
    @State private var chosen = "Ready to play"
    @State private var autonomous = true
    @FocusState private var focusedTile: String?
    private let ink = Color(red: 0.13, green: 0.23, blue: 0.38)
    private let blue = Color(red: 0.84, green: 0.93, blue: 0.99)
    private let categories = ["Play together", "Expressions", "Activities", "Outfits", "Animations"]
    private var choices: [PetChoice] {
        switch page {
        case "Expressions": return AvatarMapping.expressions.map { PetChoice(id: $0, title: $0.capitalized, icon: expressionIcon($0)) }
        case "Activities": return ["typing", "reading", "writing", "idea", "drinking", "listening", "cooking", "searching", "working", "talking", "sleeping"].map { PetChoice(id: $0, title: $0 == "idea" ? "Thinking" : $0.capitalized, icon: activityIcon($0)) }
        case "Outfits": return zip(AvatarMapping.outfits, ["sparkles", "tshirt", "book", "gamecontroller", "magnifyingglass", "wand.and.stars", "umbrella", "snowflake", "sun.max", "moon.stars"]).map { PetChoice(id: $0.0, title: $0.0.capitalized, icon: $0.1) }
        case "Animations": return [PetChoice(id: "walk", title: "Walk", icon: "figure.walk"), PetChoice(id: "run", title: "Run", icon: "figure.run")] + AvatarMapping.animations.filter { !["idle", "walk", "run", "talk"].contains($0) }.map { PetChoice(id: $0, title: $0.capitalized, icon: "sparkles") }
        default: return [PetChoice(id: "pet", title: "Pet", icon: "hand.draw"), PetChoice(id: "poke", title: "Poke", icon: "hand.point.up.left"), PetChoice(id: "highFive", title: "High five", icon: "hand.raised"), PetChoice(id: "wave", title: "Wave", icon: "hand.wave"), PetChoice(id: "dance", title: "Dance", icon: "music.note"), PetChoice(id: "jump", title: "Jump", icon: "arrow.up"), PetChoice(id: "spin", title: "Twirl", icon: "arrow.trianglehead.2.clockwise.rotate.90"), PetChoice(id: "followCursor", title: bridge.followingCursor ? "Stop following" : "Follow cursor", icon: "cursorarrow.rays"), PetChoice(id: "nap", title: "Nap", icon: "moon.zzz"), PetChoice(id: "wake", title: "Wake / stretch", icon: "sun.max")]
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "leaf.fill").foregroundStyle(.teal).symbolEffect(.bounce, value: chosen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MEWPON").font(.system(size: 17, weight: .heavy, design: .monospaced)).tracking(2)
                    Text("A little time to play").font(.system(size: 10, design: .rounded))
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22) }.buttonStyle(.plain).help("Close Play Mode · Escape").accessibilityLabel("Close Play Mode")
            }
            HStack(spacing: 4) {
                ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                    Button { page = category } label: { Image(systemName: ["heart", "face.smiling", "laptopcomputer", "tshirt", "figure.dance"][index]).frame(maxWidth: .infinity).frame(height: 30).background(page == category ? Color.white : Color.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 7)) }
                        .buttonStyle(.plain).help(category).accessibilityLabel(category)
                }
            }
            HStack { Text(page).font(.system(size: 13, weight: .bold, design: .rounded)); Spacer() }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                    ForEach(choices) { choice in
                        Button { select(choice) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: choice.icon).font(.system(size: 17)).frame(height: 20)
                                Text(choice.title).font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).frame(height: 54)
                        }.buttonStyle(PetTileStyle()).accessibilityLabel(choice.title)
                            .focusable().focused($focusedTile, equals: choice.id)
                    }
                }.padding(2)
            }.scrollIndicators(.hidden)
            Text(bridge.petAction == "highFive" ? "Click the glowing raised paw!" : chosen).font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(2).frame(height: 26)
                .accessibilityLabel("Pet status: " + (bridge.petAction ?? chosen))
            HStack {
                Toggle("Quiet surprises", isOn: $autonomous).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10)).onChange(of: autonomous) { _, value in bridge.autonomousIdle(value) }
                Spacer()
                Button { bridge.interact("random"); chosen = "A little surprise!" } label: { Image(systemName: "dice"); Text("Random") }.font(.system(size: 10, weight: .semibold)).buttonStyle(.plain).accessibilityLabel("Random action")
            }
        }.padding(16).foregroundStyle(ink)
            .background(LinearGradient(colors: [.white, blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(red: 0.45, green: 0.67, blue: 0.83), lineWidth: 2).allowsHitTesting(false))
            .padding(5).background(.clear).ignoresSafeArea().onExitCommand(perform: close)
            .onAppear { focusedTile = choices.first?.id }
            .onChange(of: page) { _, _ in focusedTile = choices.first?.id }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { key in
                guard let index = choices.firstIndex(where: { $0.id == focusedTile }) else { focusedTile = choices.first?.id; return .handled }
                if key.key == .return { select(choices[index]) }
                else { let delta = key.key == .leftArrow ? -1 : key.key == .rightArrow ? 1 : key.key == .upArrow ? -3 : 3
                    focusedTile = choices[min(choices.count - 1, max(0, index + delta))].id }
                return .handled
            }
    }
    private func select(_ item: PetChoice) {
        chosen = item.title
        switch page {
        case "Expressions": bridge.setExpression(item.id)
        case "Activities": bridge.playActivity(item.id)
        case "Outfits": bridge.setOutfit(item.id)
        case "Animations": bridge.playAnimation(item.id)
        default: bridge.interact(item.id)
        }
    }
    private func expressionIcon(_ value: String) -> String {
        ["neutral":"face.smiling", "happy":"heart", "excited":"sparkles", "thinking":"thought.bubble", "confused":"questionmark", "sad":"cloud.rain", "angry":"flame", "sleepy":"moon.zzz", "wink":"eye", "laugh":"face.smiling.inverse", "surprised":"exclamationmark", "embarrassed":"heart.circle", "proud":"star", "focused":"scope"][value] ?? "face.smiling"
    }
    private func activityIcon(_ value: String) -> String {
        ["typing":"keyboard", "reading":"book", "writing":"pencil", "idea":"lightbulb", "drinking":"cup.and.saucer", "listening":"headphones", "cooking":"frying.pan", "searching":"magnifyingglass", "working":"laptopcomputer", "talking":"text.bubble", "sleeping":"moon.zzz"][value] ?? "sparkles"
    }
}

private struct PetTileStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color(red: 0.65, green: 0.83, blue: 0.95) : Color.white.opacity(hovering ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 0.6, green: 0.77, blue: 0.89), lineWidth: 1))
            .offset(y: configuration.isPressed ? 1 : 0).onHover { hovering = $0 }
    }
}
