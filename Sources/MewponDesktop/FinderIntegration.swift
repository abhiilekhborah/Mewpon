import AppKit
import SwiftUI
import QuickLookUI
import MewponCore
import UniformTypeIdentifiers

struct NativeFileRow: View {
    let item: ResultItem
    var selected = false
    let busy: Bool
    @ObservedObject var model: AssistantModel
    var select: (() -> Void)? = nil
    private var location: String {
        let folder = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return folder == home ? "~" : folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack { Text(item.kind.isEmpty ? "Item" : item.kind.uppercased()); if let date = item.modifiedAt { Text(date, style: .date) } }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Open") { model.openResult(item) }.foregroundStyle(MewponDesign.accent)
            Menu { Button("Reveal in Finder") { model.fileAction(item, action: "reveal") }; Button("Quick Look") { model.fileAction(item, action: "preview") }; Button("Read text locally…") { model.runDirect(ToolCall(name: "read_document", arguments: ["path": .string(item.path)])) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }.padding(11).background(selected ? MewponDesign.accent.opacity(0.17) : .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9)).contentShape(RoundedRectangle(cornerRadius: 9))
            .onTapGesture(count: 2) { if !busy && !model.paused { model.openResult(item) } }
            .onTapGesture { select?() }
            .help(item.path).buttonStyle(.borderless).controlSize(.small).disabled(busy || model.paused)
    }
}

@MainActor final class FilePreview {
    static let shared = FilePreview()
    private var window: NSWindow?
    private var preview: QLPreviewView?
    func show(_ url: URL) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Mewpon Quick Look"
            let preview = QLPreviewView(frame: window.contentView!.bounds, style: .normal)!
            preview.autoresizingMask = [.width, .height]; preview.shouldCloseWithWindow = true
            window.contentView = preview; self.preview = preview; self.window = window; window.center()
        }
        preview?.previewItem = url as NSURL
        window?.makeKeyAndOrderFront(nil)
    }
}

struct FinderActionTool: AssistantTool {
    let spec = ToolSpec("finder_action", "Reveal or preview an existing absolute file path. action must be reveal or preview. Never invent paths.", fields: ["path": "Existing absolute path", "action": "reveal or preview"], capability: .inspectFile)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let path = arguments["path"]!.string!, action = arguments["action"]!.string!
        guard path.hasPrefix("/"), ["reveal", "preview"].contains(action) else { return ToolResult(false, "Choose an existing file and a supported action.") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path), FileManager.default.isReadableFile(atPath: url.path) else { return ToolResult(false, "File missing or access denied by macOS.") }
        try Task.checkCancellation()
        return await MainActor.run {
            if action == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { FilePreview.shared.show(url) }
            return ToolResult(true, action == "reveal" ? "Revealed in Finder." : "Opened Quick Look preview.")
        }
    }
}

extension AssistantModel {
    func fileAction(_ item: ResultItem, action: String) { runDirect(ToolCall(name: "finder_action", arguments: ["path": .string(item.path), "action": .string(action)])) }
    func chooseAttachment() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.attachResult(url) }
        }
    }
    private func attachResult(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path), !busy else { return }
        entries.append(ChatEntry(role: "tool", text: "Selected file", result: ToolResult(true, "Choose Open, Reveal in Finder, or Quick Look. Use Read text locally for plain text, PDF text, or image OCR; reading requires approval.", items: [ResultItem(name: url.lastPathComponent, path: url.path, kind: url.pathExtension)])))
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, !paused, let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] value, _ in
                let url = DroppedContent.url(value)
                Task { @MainActor in
                    guard let self, let url, url.isFileURL else { return }
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard FileManager.default.fileExists(atPath: url.path) else { self.issue = "Dropped file is unavailable."; return }
                    self.attachResult(url)
                }
            }; return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] value, _ in
                let url = DroppedContent.url(value)
                Task { @MainActor in
                    guard let self, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.absoluteString.count <= 4000, !self.busy else { return }
                    self.input = url.absoluteString
                    self.issue = "URL attached as text. Mewpon does not fetch web pages."
                }
            }; return true
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                Task { @MainActor in
                    guard let self, let text = value as? String, !self.busy else { return }
                    guard text.count <= 4000 else { self.issue = "Drop text under 4000 characters."; return }
                    self.droppedText = text; self.input = text; self.focusRequest += 1
                }
            }; return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier), let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { [weak self] data, error in
                Task { @MainActor in
                    guard let self, !self.busy, let data else { return }
                    do { let url = try DroppedContent.shared.stageImage(data); self.attachResult(url) }
                    catch { self.issue = error.localizedDescription }
                }
            }; return true
        }
        issue = "Drop a file, folder, or plain text. URLs can be pasted as text; Mewpon does not fetch web pages."
        return false
    }
}
