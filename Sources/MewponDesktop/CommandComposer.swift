import AppKit
import SwiftUI

/// Owns focus as an AppKit lifecycle operation, not as a SwiftUI boolean guess.
@MainActor final class ComposerFocus: ObservableObject {
    @Published var focused = false
    weak var editor: CommandTextView?
    var onFulfilled: (() -> Void)?
    private var pending = false
    func request() { pending = true; fulfill() }
    func attach(_ editor: CommandTextView) { self.editor = editor; fulfill() }
    func fulfill() {
        guard pending, let editor, let window = editor.window, window.isVisible,
              window.isKeyWindow, window.attachedSheet == nil else { return }
        pending = window.firstResponder === editor ? false : !window.makeFirstResponder(editor)
        if !pending { onFulfilled?() }
    }
    func cancel() { pending = false }
}

final class CommandTextView: NSTextView {
    weak var focus: ComposerFocus?
    var submit: (() -> Void)?
    var escape: (() -> Void)?
    var focusChanged: ((Bool) -> Void)?
    var mounted: (() -> Void)?
    var navigate: ((UInt16) -> Bool)?
    private var keyObserver: NSObjectProtocol?
    private let placeholderStorage = NSTextStorage()
    private let placeholderLayout = NSLayoutManager()
    private let placeholderContainer = NSTextContainer(size: .zero)
    private var placeholderConfigured = false
    var placeholderColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    override var string: String {
        get { super.string }
        set { super.string = newValue; needsDisplay = true }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let font, let container = textContainer else { return }
        if !placeholderConfigured {
            placeholderStorage.addLayoutManager(placeholderLayout)
            placeholderLayout.addTextContainer(placeholderContainer)
            placeholderConfigured = true
        }
        // Use TextKit for both placeholder and input, including the same baseline,
        // line-fragment padding, text origin and native font metrics.
        placeholderContainer.size = container.size
        placeholderContainer.lineFragmentPadding = container.lineFragmentPadding
        placeholderLayout.usesFontLeading = layoutManager?.usesFontLeading ?? true
        placeholderStorage.setAttributedString(NSAttributedString(string: "Ask Mewpon anything…", attributes: [.font: font, .foregroundColor: placeholderColor]))
        placeholderLayout.ensureLayout(for: placeholderContainer)
        placeholderLayout.drawGlyphs(forGlyphRange: placeholderLayout.glyphRange(for: placeholderContainer), at: textContainerOrigin)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focus?.fulfill() }
        }
        mounted?(); focus?.attach(self)
    }
    override func layout() { super.layout(); mounted?(); focus?.fulfill() }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged?(true) }; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged?(false) }; return result
    }
    override func mouseDown(with event: NSEvent) {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if window?.isKeyWindow != true { window?.makeKeyAndOrderFront(nil) }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        // Let the input manager commit marked text before interpreting Return.
        if !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
            else { submit?() }
            return
        }
        if !hasMarkedText(), event.keyCode == 53 { escape?(); return }
        if !hasMarkedText(), navigate?(event.keyCode) == true { return }
        super.keyDown(with: event)
    }
    deinit { if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) } }
}

/// Scroll view and padding explicitly forward clicks; the whole editor surface
/// is text-entry space, and cannot initiate window-background dragging.
final class ComposerSurface: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func layout() {
        super.layout()
        if let editor = documentView as? CommandTextView, abs(editor.frame.width - contentSize.width) > 0.5 {
            editor.setFrameSize(NSSize(width: contentSize.width, height: max(48, editor.frame.height)))
        }
    }
    override func mouseDown(with event: NSEvent) {
        if let text = documentView as? CommandTextView {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if window?.isKeyWindow != true { window?.makeKeyAndOrderFront(nil) }
            if window?.firstResponder !== text { window?.makeFirstResponder(text) }
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

struct CommandComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focus: ComposerFocus
    let ready: Bool
    let submit: () -> Void
    let escape: () -> Void
    let changed: () -> Void
    var navigate: ((UInt16) -> Bool)? = nil
    var placeholderColor: NSColor? = nil
    var textColor: NSColor? = nil
    var accentColor: NSColor? = nil
    var monospace = false
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ComposerSurface {
        let scroll = ComposerSurface()
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true; scroll.automaticallyAdjustsContentInsets = false
        let editor = CommandTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.allowsUndo = true
        editor.drawsBackground = false; editor.font = monospace ? .monospacedSystemFont(ofSize: 15, weight: .regular) : .systemFont(ofSize: 15)
        editor.placeholderColor = placeholderColor ?? .secondaryLabelColor
        editor.textColor = textColor ?? .labelColor; editor.insertionPointColor = accentColor ?? .controlAccentColor
        editor.textContainerInset = NSSize(width: 12, height: 14)
        editor.minSize = NSSize(width: 0, height: 48)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.setAccessibilityLabel("Ask Mewpon anything")
        editor.delegate = context.coordinator; editor.focus = focus
        editor.submit = submit; editor.escape = escape; editor.navigate = navigate
        editor.focusChanged = { [weak focus] value in focus?.focused = value }
        editor.mounted = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        scroll.documentView = editor
        context.coordinator.editor = editor
        return scroll
    }
    func updateNSView(_ view: ComposerSurface, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? CommandTextView else { return }
        // Never replace storage or selection on a stream update or during IME.
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text; context.coordinator.measure()
        }
        editor.placeholderColor = placeholderColor ?? .secondaryLabelColor
        editor.textColor = textColor ?? .labelColor; editor.insertionPointColor = accentColor ?? .controlAccentColor
        let desiredFont: NSFont = monospace ? .monospacedSystemFont(ofSize: 15, weight: .regular) : .systemFont(ofSize: 15)
        if !editor.hasMarkedText(), editor.font != desiredFont { editor.font = desiredFont; context.coordinator.measure() }
        editor.isEditable = ready; editor.submit = submit; editor.escape = escape; editor.navigate = navigate
        focus.attach(editor)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandComposer
        weak var editor: CommandTextView?
        init(_ parent: CommandComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            parent.text = editor.string; parent.changed(); measure()
        }
        func measure() {
            guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return }
            manager.ensureLayout(for: container)
            let naturalHeight=max(48,ceil(manager.usedRect(for:container).height)+28)
            let value=min(96,naturalHeight)
            if let scroll=editor.enclosingScrollView {scroll.hasVerticalScroller=naturalHeight>96}
            if abs(parent.height - value) > 1 {
                // A layout binding update is deferred to the next run-loop pass,
                // not used as a timer or a focus workaround.
                DispatchQueue.main.async { [weak self] in self?.parent.height = value }
            }
        }
    }
}
