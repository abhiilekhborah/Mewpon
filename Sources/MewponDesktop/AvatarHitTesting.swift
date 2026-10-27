import AppKit
import WebKit

/// Event-driven alpha hit testing. Observes pointer motion only, never keys or screen pixels.
@MainActor final class AvatarHitTesting {
    private weak var panel: NSPanel?
    private weak var avatar: WKWebView?
    private var global: Any?
    private var local: Any?
    private var inFlight = false
    var enabled: () -> Bool = { false }
    init(panel: NSPanel, avatar: WKWebView) {
        self.panel = panel; self.avatar = avatar
        global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in MainActor.assumeIsolated { self?.update() }; return event }
    }
    func update() {
        guard let panel, let avatar else { return }
        guard enabled(), panel.isVisible else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return } // Never interrupt an avatar drag.
        let screenPoint = NSEvent.mouseLocation
        guard panel.frame.contains(screenPoint) else { panel.ignoresMouseEvents = true; return }
        let point = avatar.convert(panel.convertPoint(fromScreen: screenPoint), from: nil)
        guard avatar.bounds.contains(point) else { panel.ignoresMouseEvents = true; return }
        guard !inFlight else { return }; inFlight = true
        let y = avatar.isFlipped ? point.y : avatar.bounds.height - point.y
        Task { [weak self, weak panel, weak avatar] in
            guard let self, let panel, let avatar else { return }
            defer { inFlight = false }
            do {
                let hit = try await avatar.callAsyncJavaScript("const c=document.getElementById('stage');const r=c.getBoundingClientRect();const px=Math.floor(x*c.width/r.width),py=Math.floor(y*c.height/r.height);if(px<0||py<0||px>=c.width||py>=c.height)return false;return c.getContext('2d').getImageData(px,py,1,1).data[3]>12;", arguments: ["x": point.x, "y": y], in: nil, contentWorld: .page) as? Bool ?? true
                if enabled(), NSEvent.pressedMouseButtons == 0 { panel.ignoresMouseEvents = !hit }
            } catch { if enabled(), panel.isVisible { panel.ignoresMouseEvents = false } } // Keep mascot usable if the renderer is loading.
        }
    }
    deinit {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
    }
}
