import SwiftUI
import MewponCore

struct AssistantView: View {
    @ObservedObject var model: AssistantModel
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var avatar: AvatarBridge
    @ObservedObject var focus: ComposerFocus
    var settings: () -> Void
    var hide: () -> Void
    var minimize: () -> Void
    @State private var followOutput = true
    @State private var userScrolling = false
    @State private var composerHeight: CGFloat = 48
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            AvatarView(bridge: avatar)
                .frame(width: 210, height: 158)
                .accessibilityLabel("Mewpon avatar. Click for Play or assistant; drag to move.")
                .contextMenu { Button("Play with Mewpon") { avatar.onPlayRequested?() }; Button("Open assistant") { model.expand() }; Button("Settings…", action: settings); Button("Hide Mewpon", action: hide) }
            if model.expanded {
                VStack(spacing: 0) {
                    header
                    transcript
                    if let issue = model.issue ?? avatar.error {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            Text(issue).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button("Retry") { model.retry() }
                        }.font(.caption).padding(.horizontal, 20).padding(.vertical, 10)
                    }
                    composer.padding(.horizontal, 14).padding(.bottom, 10)
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield").font(.system(size: 9))
                        Text("On this Mac").font(.system(size: 10))
                        Spacer()
                        Text(model.configuration.model).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 14)
                }
                .frame(width: MewponDesign.panelWidth)
                .companionGlass(radius: 26)
                .shadow(color: .black.opacity(0.13), radius: 20, y: 10)
                .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .frame(width: model.expanded ? 500 : 220, height: model.expanded ? model.windowHeight : 176, alignment: .top)
        .ignoresSafeArea()
        .tint(MewponDesign.accent)
        .onDrop(of: [.fileURL, .utf8PlainText, .url, .image], isTargeted: nil) { model.acceptDrop($0) }
        .onChange(of: composerHeight) { _, value in model.composerHeight = value }
        .onChange(of: model.focusRequest) { _, _ in focus.request() }
        .onChange(of: model.expanded) { _, expanded in if expanded { focus.request() } else { focus.cancel() } }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mewpon").font(.system(size: 18, weight: .semibold, design: .rounded))
                HStack(spacing: 6) {
                    Circle().fill(model.busy ? MewponDesign.accent : .mint).frame(width: 4, height: 4)
                    Text(model.busy ? model.status : "Local AI · Ready").font(.system(size: 10.5)).lineLimit(1)
                }.foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("New conversation") { model.newConversation() }.disabled(model.busy)
                Button("Choose file…") { model.chooseFile() }.disabled(model.busy)
                Divider(); Button("Settings…", action: settings)
                Button("Minimize", action: minimize); Button("Hide Mewpon", action: hide)
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Assistant options")
            Button { model.collapse() } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).frame(width: 26, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Collapse assistant")
        }.padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 12)
            .overlay { WindowDragRegion().padding(.trailing, 100) }
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if model.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("A little help,\nright where you are.").font(.system(size: 25, weight: .medium, design: .rounded)).tracking(-0.6)
                            Text("Ask a question. Find a file. Make room for what matters.").font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(3)
                            HStack(spacing: 7) {
                                Button("Battery status") { model.input = "How much battery do I have?"; model.submit() }
                                Button("What can you do?") { model.input = "What can you help me with?"; model.submit() }
                            }.buttonStyle(.bordered).controlSize(.small).padding(.top, 6).disabled(model.busy)
                        }.padding(.vertical, 22)
                    }
                    ForEach(model.entries) { entry in
                        MessageRow(entry: entry, busy: model.busy, model: model, open: model.openResult).id(entry.id)
                    }
                    if model.busy { HStack(spacing: 6) { Circle().fill(MewponDesign.accent).frame(width: 4, height: 4); Text("Working locally").font(.system(size: 10.5)).foregroundStyle(.secondary) }.accessibilityLabel("Local generation in progress") }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            .modifier(TranscriptTracking(follow: $followOutput, interacting: $userScrolling))
            .overlay(alignment: .bottomTrailing) {
                if !followOutput {
                    Button { followOutput = true; proxy.scrollTo("latest", anchor: .bottom) } label: { Label("Latest", systemImage: "arrow.down") }
                        .font(.caption).buttonStyle(.bordered).padding(8)
                }
            }
            .onChange(of: model.entries.last?.text) { _, _ in if followOutput && !userScrolling { proxy.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: model.entries.count) { _, _ in if followOutput && !userScrolling { proxy.scrollTo("latest", anchor: .bottom) } }
        }.frame(height: model.transcriptHeight)
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if model.input.isEmpty { Text(model.ready ? "Ask Mewpon anything…" : "Starting up…").font(.system(size: 14)).foregroundStyle(.secondary).padding(.leading, 12).padding(.top, 14).allowsHitTesting(false) }
                CommandComposer(text: $model.input, height: $composerHeight, focus: focus, ready: model.ready,
                                submit: model.submit, escape: { model.busy ? model.cancel() : model.collapse() }, changed: model.typing)
            }.frame(height: composerHeight)
            Button {
                model.busy ? model.cancel() : model.submit()
            } label: {
                Image(systemName: model.busy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
                    .foregroundStyle(model.busy || !model.input.isEmpty ? Color.white : Color.secondary)
                    .background(model.busy || !model.input.isEmpty ? MewponDesign.accent : .primary.opacity(0.06), in: Circle())
            }.buttonStyle(.plain).disabled(!model.ready || (!model.busy && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
             .help(model.busy ? "Stop generation" : "Send · Return; Shift–Return for a new line").padding(.trailing, 9).padding(.bottom, 9)
        }
        .background(.background.opacity(0.50), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(focus.focused ? MewponDesign.accent.opacity(0.7) : .primary.opacity(0.07), lineWidth: focus.focused ? 1.2 : 0.5).allowsHitTesting(false))
    }
}

private struct MessageRow: View {
    let entry: ChatEntry
    let busy: Bool
    let model: AssistantModel
    let open: (ResultItem) -> Void
    var body: some View {
        if let result = entry.result {
            VStack(alignment: .leading, spacing: 8) {
                Label(result.summary, systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(result.success ? Color.secondary : .orange).textSelection(.enabled)
                ForEach(result.items) { item in
                    NativeFileRow(item: item, busy: busy, model: model)
                }
            }
        } else if entry.role == "user" {
            HStack { Spacer(minLength: 36); Text(entry.text).font(.system(size: 12.5)).textSelection(.enabled).padding(.horizontal, 12).padding(.vertical, 9).background(MewponDesign.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)) }
        } else { MarkdownMessage(text: entry.text).equatable() }
    }
}

struct TranscriptTracking: ViewModifier {
    @Binding var follow: Bool
    @Binding var interacting: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in interacting = phase == .interacting || phase == .tracking || phase == .decelerating }
                .onScrollGeometryChange(for: Bool.self, of: { $0.contentSize.height - $0.contentOffset.y - $0.containerSize.height < 56 }) { _, nearBottom in
                    if interacting || nearBottom { follow = nearBottom }
                }
        } else {
            content.background(LegacyScrollTracking(follow: $follow))
        }
    }
}

private struct LegacyScrollTracking: NSViewRepresentable {
    @Binding var follow: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { context.coordinator.attach(view) }; return view }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.parent = self }
    final class Coordinator {
        var parent: LegacyScrollTracking
        var observer: NSObjectProtocol?
        init(_ parent: LegacyScrollTracking) { self.parent = parent }
        func attach(_ view: NSView) {
            var ancestor = view.superview
            while ancestor != nil, !(ancestor is NSScrollView) { ancestor = ancestor?.superview }
            guard let scroll = ancestor as? NSScrollView else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll, let doc = scroll.documentView else { return }
                    let near = doc.bounds.height - scroll.contentView.bounds.maxY < 56
                    if NSApp.currentEvent?.type == .scrollWheel || near { self.parent.follow = near }
                }
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
