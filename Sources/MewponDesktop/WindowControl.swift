import AppKit
import ApplicationServices
import MewponCore

@MainActor enum WindowControlSource {
    static var bundleID: String?
    static func remember() {
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier { bundleID = app.bundleIdentifier }
    }
}
struct WindowControlTool: AssistantTool {
    let spec = ToolSpec("window_control", "Move a focused application window left/right/center/next-monitor, minimize, restore, close, or open application preferences. Requires Accessibility; never clicks screen coordinates.", fields: ["application": "Exact running application name or bundle ID", "action": "left, right, center, next-monitor, minimize, restore, close, preferences"], capability: .windowControl)
    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func target(action: String, current: CGRect, visible: CGRect) -> CGRect {
        switch action {
        case "left": return CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
        case "right": return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
        default:
            let size = CGSize(width: min(current.width, visible.width), height: min(current.height, visible.height))
            return CGRect(x: visible.midX-size.width/2, y: visible.midY-size.height/2, width: size.width, height: size.height)
        }
    }
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard AXIsProcessTrusted() else { return ToolResult(false, "Enable Accessibility once in Settings → Permissions → Automation & Permissions, then retry. No window changed.") }
        let name = arguments["application"]!.string!, action = arguments["action"]!.string!
        guard ["left", "right", "center", "next-monitor", "minimize", "restore", "close", "preferences"].contains(action) else { return ToolResult(false, "Unsupported window action.") }
        let snapshot = await MainActor.run { (NSWorkspace.shared.runningApplications, WindowControlSource.bundleID, NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }, Bundle.main.bundleIdentifier) }
        let work = Task.detached {
            let resolvedName = name == "frontmost" ? (snapshot.1 ?? "") : name
            let apps = snapshot.0.filter { $0.bundleIdentifier != snapshot.3 && ($0.localizedName?.caseInsensitiveCompare(resolvedName) == .orderedSame || $0.bundleIdentifier?.caseInsensitiveCompare(resolvedName) == .orderedSame) }
            guard apps.count == 1, let app = apps.first else { return ToolResult(false, "Choose one exact running application. No window changed.") }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.3)
            if action == "preferences" {
                guard let menu = Self.attribute(root, kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() else { return ToolResult(false, "This app exposes no accessible menu bar.") }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                var queue: [(AXUIElement, Int)] = [(unsafeBitCast(menu, to: AXUIElement.self), 0)], visited = 0
                while !queue.isEmpty, visited < 120, ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    let (node, depth) = queue.removeFirst(); visited += 1
                    let title = Self.attribute(node, kAXTitleAttribute) as? String ?? ""
                    if ["Settings…", "Settings...", "Preferences…", "Preferences..."].contains(title) {
                        let ok = AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
                        return ToolResult(ok, ok ? "Requested \(name) preferences." : "The preferences menu item refused the request.")
                    }
                    if depth < 4, let children = Self.attribute(node, kAXChildrenAttribute) as? [AXUIElement] { queue += children.map { ($0, depth+1) } }
                }
                return ToolResult(false, "No unambiguous accessible preferences item was found. Use the app's Settings menu.")
            }
            let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let focused = Self.attribute(root, kAXFocusedWindowAttribute)
            let window: AXUIElement?
            if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() { window = unsafeBitCast(focused, to: AXUIElement.self) }
            else { window = windows.count == 1 ? windows.first : nil }
            guard let window else { return ToolResult(false, "Activate the intended window in \(name), then retry. No window was selected arbitrarily.") }
            if ["minimize", "restore"].contains(action) {
                let wanted = action == "minimize"
                let ok = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, wanted ? kCFBooleanTrue : kCFBooleanFalse) == .success
                let verified = Self.attribute(window, kAXMinimizedAttribute) as? Bool == wanted
                if !wanted { _ = await MainActor.run { app.activate(options: []) } }
                return ToolResult(ok && verified, ok && verified ? "\(name) window \(wanted ? "minimized" : "restored")." : "The window did not confirm the requested state.")
            }
            if action == "close" {
                guard let button = Self.attribute(window, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() else { return ToolResult(false, "No accessible close button was found.") }
                let ok = AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString) == .success
                return ToolResult(ok, ok ? "Requested normal window close. The app may ask to save unsaved work." : "Window close was refused.")
            }
            guard let current = Self.frame(window), let primary = snapshot.2.first else { return ToolResult(false, "The window does not expose a movable frame.") }
            let center = CGPoint(x: current.midX, y: primary.frame.maxY-current.midY)
            let screens = snapshot.2
            var index = screens.firstIndex { $0.frame.contains(center) } ?? 0
            if action == "next-monitor" {
                guard screens.count > 1 else { return ToolResult(false, "Only one monitor is connected.") }
                index = (index+1) % screens.count
            }
            let ns = screens[index].visibleFrame
            let visible = CGRect(x: ns.minX, y: primary.frame.maxY-ns.maxY, width: ns.width, height: ns.height)
            let target = Self.target(action: action, current: current, visible: visible)
            var point = target.origin, size = target.size
            guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return ToolResult(false, "Could not encode the requested frame.") }
            try Task.checkCancellation()
            let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
            let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
            guard sized == .success, moved == .success, let actual = Self.frame(window) else { return ToolResult(false, "The app refused part of the resize/move. Its window may have changed partially.") }
            let matches = abs(actual.minX-target.minX) <= 3 && abs(actual.minY-target.minY) <= 3 && abs(actual.width-target.width) <= 8 && abs(actual.height-target.height) <= 8
            return ToolResult(matches, matches ? "\(name) window: \(action)." : "The app constrained the window to \(Int(actual.width)) × \(Int(actual.height)); exact placement was not confirmed.")
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

struct MinimizeOtherWindowsTool: AssistantTool {
    let spec = ToolSpec("minimize_other_windows", "Minimize accessible windows in regular apps except one exact app. Excludes Mewpon and background/system apps.", fields: ["except": "Exact app name or bundle ID"], capability: .windowControl)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard AXIsProcessTrusted() else { return ToolResult(false, "Accessibility permission is required. No windows changed.") }
        let snapshot = await MainActor.run { (NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }, Bundle.main.bundleIdentifier) }
        let work = Task.detached {
            let name = arguments["except"]!.string!
            let apps = snapshot.0
            let except = apps.filter { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == OpenApplicationTool.bundleIdentifier(for: name) }
            guard except.count == 1 else { return ToolResult(false, "Choose one exact running app to leave visible.") }
            var count = 0, failed = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            for app in apps where app.processIdentifier != except[0].processIdentifier && app.bundleIdentifier != snapshot.1 {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { return ToolResult(false, "Stopped at the time limit after minimizing \(count) windows; remaining windows were not attempted.") }
                let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root, 0.5)
                for window in (WindowControlTool.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(30) {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { return ToolResult(false, "Stopped at the time limit after minimizing \(count) windows; remaining windows were not attempted.") }
                    if WindowControlTool.attribute(window, kAXMinimizedAttribute) as? Bool == true { continue }
                    if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success, WindowControlTool.attribute(window, kAXMinimizedAttribute) as? Bool == true { count += 1 } else { failed += 1 }
                }
            }
            return ToolResult(failed == 0, "Minimized \(count) windows; \(failed) could not be verified.")
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
