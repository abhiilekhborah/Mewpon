import AppKit
import Combine

private final class ApprovalSheet: NSPanel {
    var deny: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { deny?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 36 { deny?() } else { super.keyDown(with: event) }
    }
}

/// Only the Allow button target can grant a request. A sheet return code never grants access.
@MainActor final class PermissionPresenter: NSObject {
    private let manager: PermissionManager
    private let parent: () -> NSWindow
    private let canPresent: () -> Bool
    private var subscription: AnyCancellable?
    private var sheet: ApprovalSheet?
    private var requestID: UUID?
    init(manager: PermissionManager, canPresent: @escaping () -> Bool = { true }, parent: @escaping () -> NSWindow) {
        self.manager = manager; self.parent = parent; self.canPresent = canPresent
        super.init()
        subscription = manager.$pending.sink { [weak self] request in self?.present(request) }
    }
    func refresh() { if sheet == nil { present(manager.pending) } }
    private func present(_ request: PermissionRequest?) {
        guard let request else {
            requestID = nil
            if let sheet { sheet.sheetParent?.endSheet(sheet, returnCode: .abort) }
            sheet = nil
            return
        }
        guard canPresent() else { return }
        guard sheet == nil else { manager.resolve(false, requestID: request.id); return }
        let panel = ApprovalSheet(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Review Mewpon action"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.deny = { [weak self] in self?.deny() }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14; root.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Allow this Mewpon action?"); title.font = .boldSystemFont(ofSize: 17)
        let capability = NSTextField(wrappingLabelWithString: request.capability.label); capability.font = .systemFont(ofSize: 13, weight: .medium)
        let arguments = request.arguments.keys.sorted().map { $0.capitalized + ": " + (request.arguments[$0]?.string ?? "") }.joined(separator: "\n")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let details = NSTextView(); details.isEditable = false; details.isSelectable = true; details.isRichText = false; details.drawsBackground = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular); details.textColor = .labelColor; details.string = arguments.isEmpty ? "No additional arguments." : arguments
        details.textContainer?.widthTracksTextView = true; details.isVerticallyResizable = true; details.autoresizingMask = [.width]
        scroll.documentView = details
        let note = NSTextField(wrappingLabelWithString: "Only Allow once approves this exact action. Return, Escape, closing, or cancelling denies it. macOS privacy restrictions still apply.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let deny = NSButton(title: "Deny", target: self, action: #selector(denyAction)); deny.identifier = NSUserInterfaceItemIdentifier("permission-deny"); deny.keyEquivalent = "\u{1b}"
        let allow = NSButton(title: "Allow once", target: self, action: #selector(allowAction)); allow.identifier = NSUserInterfaceItemIdentifier("permission-allow"); allow.keyEquivalent = ""
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [deny, spacer, allow]); buttons.orientation = .horizontal
        [title, capability, scroll, note, buttons].forEach(root.addArrangedSubview)
        panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 22), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -22), root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 22), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -22),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.heightAnchor.constraint(equalToConstant: 90), note.widthAnchor.constraint(equalTo: root.widthAnchor), buttons.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        details.setFrameSize(NSSize(width: 390, height: 90))
        requestID = request.id; sheet = panel
        let window = parent(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        window.beginSheet(panel) { [weak self] _ in
            guard let self, requestID == request.id else { return }
            // Native close/abort callbacks are denial-only, regardless of supplied return code.
            manager.resolve(false, requestID: request.id)
        }
    }
    private func deny() { guard let requestID else { return }; manager.resolve(false, requestID: requestID) }
    @objc private func denyAction(_ sender: NSButton) { deny() }
    @objc private func allowAction(_ sender: NSButton) { guard let requestID else { return }; manager.resolve(true, requestID: requestID) }
}
