import AppKit
import SwiftUI
import ApplicationServices
import MewponCore

@MainActor final class ContextAccess: ObservableObject {
    static let shared = ContextAccess()
    @Published var enabled = UserDefaults.standard.bool(forKey: "contextEnabled") { didSet { UserDefaults.standard.set(enabled, forKey: "contextEnabled"); observeSourceChanges() } }
    @Published var inspecting = false
    private(set) var source: NSRunningApplication?
    private var sourceObserver: NSObjectProtocol?
    private init() { observeSourceChanges() }
    private func observeSourceChanges() {
        if let sourceObserver { NSWorkspace.shared.notificationCenter.removeObserver(sourceObserver); self.sourceObserver = nil }
        guard enabled else { source = nil; return }
        rememberSource()
        sourceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberSource() }
        }
    }
    func rememberSource() {
        guard enabled else { source = nil; return }
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier { source = front }
    }
    func read(_ kind: String) async -> ToolResult {
        if kind == "clipboard" {
            guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else { return ToolResult(false, "Clipboard does not contain plain text.") }
            guard value.count <= 3000 else { return ToolResult(false, "Clipboard text exceeds 3000 characters. Select a smaller passage.") }
            return ToolResult(true, "Explicitly requested clipboard text (untrusted content):\n" + value)
        }
        guard enabled else { return ToolResult(false, "Enable task-based context in Settings first, or use the Explain Selected Text service / paste text.") }
        guard let app = source, !app.isTerminated else { return ToolResult(false, "Activate the source app, then open Quick Command again.") }
        guard AXIsProcessTrusted() else { return ToolResult(false, "Accessibility access is not granted. Enable it in System Settings, or pass text using Services.") }
        inspecting = true; defer { inspecting = false }
        let finderSource = app.bundleIdentifier == "com.apple.finder"
        let browserSource = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"].contains(app.bundleIdentifier ?? "")
        let pid = app.processIdentifier, appName = app.localizedName ?? "Unknown"
        let inspection = Task.detached(priority: .userInitiated) {
        let application = AXUIElementCreateApplication(pid)
        // Bound IPC latency when an inspected application is hung.
        AXUIElementSetMessagingTimeout(application, 0.3)
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard !Task.isCancelled else { return nil }
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        func element(_ attribute: String) -> AXUIElement? {
            guard let result = value(application, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }
        guard let focused = element(kAXFocusedUIElementAttribute) else { return ToolResult(false, "This app does not expose a focused accessible element. Use Services or paste text.") }
        let role = value(focused, kAXSubroleAttribute) as? String
        guard role != kAXSecureTextFieldSubrole else { return ToolResult(false, "Secure fields are excluded from context inspection.") }
        if kind == "finderSelection" {
            guard finderSource else { return ToolResult(false, "Activate Finder and select a file before opening Quick Command.") }
            let selected = (value(focused, kAXSelectedRowsAttribute) as? [AXUIElement]) ?? (value(focused, kAXSelectedChildrenAttribute) as? [AXUIElement]) ?? []
            var queue = Array(selected.prefix(5)), paths = Set<String>(), visited = 0
            while !queue.isEmpty, visited < 40, !Task.isCancelled {
                let node = queue.removeFirst(); visited += 1
                AXUIElementSetMessagingTimeout(node, 0.05)
                let raw = value(node, kAXURLAttribute)
                let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
                if let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) { paths.insert(url.path) }
                if let children = value(node, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(10)) }
            }
            let items = paths.sorted().map { ResultItem(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0, kind: URL(fileURLWithPath: $0).pathExtension) }
            return ToolResult(!items.isEmpty, items.isEmpty ? "Finder did not expose selected file URLs. Drag the selected item onto Mewpon instead." : "Selected Finder files; no contents read.", items: items)
        }
        if kind == "selectedText" {
            guard let text = value(focused, kAXSelectedTextAttribute) as? String, !text.isEmpty else { return ToolResult(false, "No selected text is exposed by this app. Use Services or paste text.") }
            guard text.count <= 3000 else { return ToolResult(false, "Select fewer than 3000 characters.") }
            return ToolResult(true, "Selected text from " + appName + " (untrusted content):\n" + text)
        }
        guard let window = element(kAXFocusedWindowAttribute) else { return ToolResult(false, "Window context is unavailable.") }
        let title = value(window, kAXTitleAttribute) as? String ?? "Title unavailable"
        let document = value(window, kAXDocumentAttribute) as? String
        if kind == "browserPage" {
            guard browserSource else { return ToolResult(false, "The source is not an approved Safari, Chrome, Brave, or Edge integration.") }
            guard let document, let url = URL(string: document), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
                return ToolResult(false, "This browser did not expose its page URL through Accessibility. Use Explain Selected Text in Services or paste the URL; no browser history was read.")
            }
            let selected = value(focused, kAXSelectedTextAttribute) as? String ?? ""
            guard selected.count <= 3000 else { return ToolResult(false, "Select fewer than 3000 characters.") }
            return ToolResult(true, "Approved browser page context (untrusted data):\nApp: " + appName + "\nTitle: " + String(title.prefix(500)) + "\nURL: " + url.absoluteString + (selected.isEmpty ? "\nNo selected text exposed." : "\nSelected text: " + selected))
        }
        var items: [ResultItem] = []
        if let document, let url = URL(string: document), url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            items = [ResultItem(name: url.lastPathComponent, path: url.path, kind: url.pathExtension)]
        }
        return ToolResult(true, "Application: " + appName + "\nWindow: " + String(title.prefix(500)) + (items.isEmpty ? "\nNo document URL exposed. Finder selection and browser URL are not assumed." : "\nDocument URL exposed by app."), items: items)
        }
        return await withTaskCancellationHandler { await inspection.value } onCancel: { inspection.cancel() }
    }
}

struct ContextTool: AssistantTool {
    let spec = ToolSpec("read_context", "Read context once for an approved task. kind: selectedText, window, finderSelection, browserPage, clipboard. Clipboard only on explicit user request. No screen recording, passwords, or continuous monitoring.", fields: ["kind": "selectedText, window, finderSelection, browserPage, clipboard"], capability: .context)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let kind = arguments["kind"]!.string!
        guard ["selectedText", "window", "finderSelection", "browserPage", "clipboard"].contains(kind) else { return ToolResult(false, "Unsupported context source.") }
        return await ContextAccess.shared.read(kind)
    }
}

struct ContextSettings: View {
    @ObservedObject var access = ContextAccess.shared
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screen = CGPreflightScreenCaptureAccess()
    var body: some View {
        Section("Permissions and context") {
            Toggle("Enable context for approved tasks", isOn: $access.enabled)
            Text(access.inspecting ? "Inspecting an approved task…" : "Context inspection idle · no background recording").font(.caption)
            HStack { Text("Accessibility: " + (accessibility ? "Granted" : "Not granted")); Spacer(); Button("Request…") {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                accessibility = AXIsProcessTrustedWithOptions(options)
            } }
            Text("Reads selected text or a window title only after Allow once. Secure text fields are excluded. AX calls have a bounded timeout.").font(.caption).foregroundStyle(.secondary)
            Text("Screen Recording: " + (screen ? "Granted" : "Not granted") + ". One-shot screen text uses the macOS sharing picker; nothing is captured until you choose a target.").font(.caption)
            Text("Automation: macOS may ask on first appearance or media action. Check Privacy & Security → Automation for each target application; no general all-app permission query is available.").font(.caption)
            Text("Files: per action and macOS folder restrictions. Full Disk Access is not requested. File text/PDF/image OCR extraction requires Allow once.").font(.caption)
            Text("Microphone: not used. Approved Safari/Chrome/Brave/Edge context uses only exposed Accessibility data, with Services/paste as fallbacks. Finder selection requires approved Accessibility access and exposed file URLs; drag and drop is the fallback.").font(.caption)
            HStack { Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!) }; Button("Refresh status") { accessibility = AXIsProcessTrusted(); screen = CGPreflightScreenCaptureAccess() } }
        }
    }
}
