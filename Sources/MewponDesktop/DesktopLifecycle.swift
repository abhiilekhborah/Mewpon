import AppKit

/// The same event path is callable in tests without sleeping or reconfiguring the Mac.
@MainActor final class DesktopLifecycle {
    enum Event { case sleep, wake, displaysChanged, spaceChanged, otherApplicationActivated }
    let onEvent: (Event) -> Void
    private var displayObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.handle(.displaysChanged) } }
        for (name, event) in [(NSWorkspace.willSleepNotification, Event.sleep), (NSWorkspace.didWakeNotification, .wake)] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.handle(event) } })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.handle(.spaceChanged) } })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.handle(.otherApplicationActivated) }
        })
    }
    func handle(_ event: Event) { onEvent(event) }
    deinit {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}

extension NSScreen {
    var mewponVisibleFrame: CGRect {
        let safe = CGRect(x: frame.minX + safeAreaInsets.left, y: frame.minY + safeAreaInsets.bottom,
                          width: frame.width - safeAreaInsets.left - safeAreaInsets.right,
                          height: frame.height - safeAreaInsets.top - safeAreaInsets.bottom)
        return visibleFrame.intersection(safe)
    }
}

extension WindowGeometry {
    static func recovered(_ current: CGRect, displays: [CGRect]) -> CGRect {
        guard !displays.isEmpty else { return current }
        let target = displays.max { a, b in
            func score(_ frame: CGRect) -> Double {
                let overlap = current.intersection(frame)
                if !overlap.isNull, overlap.width * overlap.height > 0 { return overlap.width * overlap.height }
                return -hypot(current.midX - frame.midX, current.midY - frame.midY)
            }
            return score(a) < score(b)
        }!
        return constrained(current, size: current.size, visible: target)
    }
}
