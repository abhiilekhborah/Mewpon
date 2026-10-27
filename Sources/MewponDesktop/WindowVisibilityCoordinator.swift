import AppKit
import QuartzCore

/// User intent controls visibility. App/Space changes neither hide nor summon.
@MainActor final class WindowVisibilityCoordinator {
    enum State: String { case hidden, companion, assistant }
    enum Event { case toggle, showAssistant, companion, hide, escape, workspaceChanged, sleep, wake, responseCompleted }
    private(set) var requested: State
    private(set) var suppressed = false
    var effective: State { suppressed ? .hidden : requested }
    var changed: ((State, Bool) -> Void)?
    var persist: ((State) -> Void)?
    init(initial: State) { requested = initial }
    func send(_ event: Event) {
        let before = effective
        var explicit = false
        switch event {
        case .toggle: requested = effective == .assistant ? .hidden : .assistant; suppressed = false; explicit = true
        case .showAssistant: requested = .assistant; suppressed = false; explicit = true
        case .companion: requested = .companion; suppressed = false; explicit = true
        case .hide, .escape: requested = .hidden; suppressed = false; explicit = true
        case .sleep: suppressed = true
        case .workspaceChanged, .wake, .responseCompleted: break // No automatic reappearance.
        }
        if explicit { persist?(requested) }
        if before != effective || explicit { changed?(effective, explicit) }
    }
}

/// Interruptible native window transition. A generation invalidates stale completions.
@MainActor final class WindowTransition {
    private var generation = 0
    private var animating = false
    private var destination: NSRect?
    func resize(_ window: NSWindow, frame: NSRect) {
        destination = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.3, 1)
            window.animator().setFrame(frame, display: true)
        }
    }
    func set(_ window: NSWindow, visible: Bool, frame: NSRect? = nil, focus: (() -> Void)? = nil) {
        if visible, window.isVisible, !animating, frame == nil || frame == window.frame { window.ignoresMouseEvents = false; focus?(); return }
        generation += 1; let token = generation
        let wasVisible = window.isVisible
        let target = frame ?? (animating ? destination ?? window.frame : window.frame)
        animating = true
        destination = target
        window.ignoresMouseEvents = !visible
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible {
            if !wasVisible {
                window.setFrame(reduce ? target : target.insetBy(dx: target.width * 0.018, dy: target.height * 0.018), display: false)
                window.alphaValue = reduce ? 1 : 0
            }
            window.orderFront(nil); focus?()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : (visible ? 0.18 : 0.14)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            window.animator().alphaValue = visible ? 1 : 0
            window.animator().setFrame(visible || reduce ? target : target.insetBy(dx: target.width * 0.018, dy: target.height * 0.018), display: true)
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, self.generation == token, let window else { return }
                self.animating = false
                if !visible { window.orderOut(nil); window.setFrame(target, display: false); window.alphaValue = 1 }
            }
        }
    }
}
