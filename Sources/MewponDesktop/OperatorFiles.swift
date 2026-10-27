import AppKit
import CoreServices
import UniformTypeIdentifiers
import MewponCore

struct FileOperation: Codable, Equatable, Sendable {
    let action: String
    let source: String
    let destination: String
    static func allowed(_ path: String, roots: [String]) -> Bool {
        let url = URL(fileURLWithPath: LocalPath.canonicalDestination(path))
        guard url.path != "/", url.path != NSHomeDirectory(), !url.pathComponents.contains(where: { [".ssh", ".aws", ".gnupg", "Keychains", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519"].contains($0) }) else { return false }
        guard !url.lastPathComponent.hasPrefix(".env"), !["keychain", "keychain-db"].contains(url.pathExtension) else { return false }
        return roots.contains { root in url.path == LocalPath.canonical(root) || url.path.hasPrefix(LocalPath.canonical(root) + "/") }
    }
    func apply(roots: [String], manager: FileManager = .default) throws -> ToolResult {
        guard ["copy", "move", "rename", "mkdir"].contains(action), Self.allowed(destination, roots: roots), action == "mkdir" || Self.allowed(source, roots: roots) else { throw MewponError.invalid("Choose an authorized operation folder in Settings → Permissions. Sensitive credential folders and disk/home roots are excluded.") }
        let dest = URL(fileURLWithPath: LocalPath.canonicalDestination(destination))
        guard !manager.fileExists(atPath: dest.path) else { throw MewponError.invalid("Destination already exists. Nothing was overwritten.") }
        let parent = dest.deletingLastPathComponent()
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else { throw MewponError.invalid("The destination's parent folder must already exist.") }
        if action == "mkdir" {
            try manager.createDirectory(at: dest, withIntermediateDirectories: false)
            return ToolResult(manager.fileExists(atPath: dest.path), "Created folder \(dest.lastPathComponent).")
        }
        let original = URL(fileURLWithPath: source)
        guard try original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MewponError.invalid("Source symlinks are not supported.") }
        let src = URL(fileURLWithPath: LocalPath.canonicalDestination(source))
        let values = try src.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true, src.path != dest.path, !dest.path.hasPrefix(src.path + "/") else { throw MewponError.invalid("Unsupported source or recursive destination. Nothing changed.") }
        try Task.checkCancellation()
        if action == "copy" { try manager.copyItem(at: src, to: dest) }
        else { try manager.moveItem(at: src, to: dest) }
        let verified = manager.fileExists(atPath: dest.path) && (action == "copy" || !manager.fileExists(atPath: src.path))
        return ToolResult(verified, verified ? "\(action.capitalized): \(dest.lastPathComponent)." : "File operation could not be verified.")
    }
}
struct FileOperationTool: AssistantTool {
    let roots: @Sendable () async -> [String]
    let spec = ToolSpec("file_operation", "Copy, move, rename, or create a folder strictly within user-authorized operation folders. Never overwrite, delete, follow source symlinks, or access credentials.", fields: ["operation": "copy, move, rename, mkdir", "source": "Absolute source path, or none for mkdir", "destination": "New absolute destination path"], capability: .fileChanges, timeout: 30)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let roots = await roots()
        let operation = FileOperation(action: arguments["operation"]!.string!, source: arguments["source"]!.string!, destination: arguments["destination"]!.string!)
        return try await Task.detached { try operation.apply(roots: roots) }.value
    }
}
actor ScreenshotPlans {
    static let shared = ScreenshotPlans()
    struct Plan { let created: Date; let folder: String; let files: [(String, Date, Int)]; let preview: String }
    private var plans: [String: Plan] = [:]
    func prepare(roots: [String]) throws -> ToolResult {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        guard FileOperation.allowed(desktop.path, roots: roots) else { return ToolResult(false, "Add Desktop as an operation folder in Settings → Permissions before organizing screenshots.") }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: desktop, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let files: [(String, Date, Int)] = try urls.compactMap { url in
            let value = try url.resourceValues(forKeys: keys)
            guard value.isRegularFile == true, value.isSymbolicLink != true, ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()), let date = value.creationDate, Calendar.current.isDateInToday(date) else { return nil }
            // Metadata identifies screenshots independent of localized filenames.
            let metadata = MDItemCreate(kCFAllocatorDefault, url.path as CFString)
            let screenshot = metadata.flatMap { MDItemCopyAttribute($0, "kMDItemIsScreenCapture" as CFString) } as? Bool ?? false
            guard screenshot else { return nil }
            return (url.path, value.contentModificationDate ?? date, value.fileSize ?? 0)
        }
        guard !files.isEmpty, files.count <= 100 else { return ToolResult(false, files.isEmpty ? "No screenshots created today were identified on Desktop." : "More than 100 screenshots matched. Narrow the operation; nothing moved.") }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let folder = desktop.appendingPathComponent("Screenshots " + formatter.string(from: Date())).path
        guard !FileManager.default.fileExists(atPath: folder) else { return ToolResult(false, "Today's screenshot folder already exists. Nothing was overwritten.") }
        plans = plans.filter { Date().timeIntervalSince($0.value.created) < 300 }
        guard plans.count < 8 else { return ToolResult(false, "Too many pending previews. Retry in a few minutes.") }
        let id = UUID().uuidString
        let preview="Preview: move \(files.count) screenshots into \(folder). Review the listed files before allowing the move."
        plans[id] = .init(created: Date(), folder: folder, files: files, preview: preview)
        return ToolResult(true, preview, items: files.map { ResultItem(name: URL(fileURLWithPath: $0.0).lastPathComponent, path: $0.0, kind: "move-plan:" + id) })
    }
    func apply(_ id: String, preview: String, roots: [String]) throws -> ToolResult {
        guard let plan = plans.removeValue(forKey: id), Date().timeIntervalSince(plan.created) < 300, preview == plan.preview, FileOperation.allowed(plan.folder, roots: roots) else { return ToolResult(false, "The preview expired or permission was revoked. Nothing moved.") }
        // Revalidate the full frozen manifest before changing the filesystem.
        for (path, date, size) in plan.files {
            let url = URL(fileURLWithPath: path), v = try URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
            guard FileOperation.allowed(path, roots: roots), v.isSymbolicLink != true, v.contentModificationDate == date, v.fileSize == size, !FileManager.default.fileExists(atPath: URL(fileURLWithPath: plan.folder).appendingPathComponent(url.lastPathComponent).path) else { return ToolResult(false, "A previewed file changed. Nothing moved; request a new preview.") }
        }
        _ = try FileOperation(action: "mkdir", source: "none", destination: plan.folder).apply(roots: roots)
        var moved: [String] = []
        do {
            for (path, _, _) in plan.files {
                try Task.checkCancellation()
                _ = try FileOperation(action: "move", source: path, destination: URL(fileURLWithPath: plan.folder).appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path).apply(roots: roots)
                moved.append(path)
            }
        } catch { return ToolResult(false, "Stopped after \(moved.count) of \(plan.files.count) moves: \(error.localizedDescription). Review \(plan.folder). Existing files were not overwritten.") }
        return ToolResult(true, "Moved \(moved.count) screenshots to \(plan.folder).")
    }
}
struct PrepareScreenshotsTool: AssistantTool {
    let roots: @Sendable () async -> [String]
    let spec = ToolSpec("prepare_screenshot_move", "Create an immutable, expiring preview of today's actual Desktop screenshots. Does not move files.", capability: .searchFiles)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult { try await ScreenshotPlans.shared.prepare(roots: await roots()) }
}
struct ApplyFileBatchTool: AssistantTool {
    let roots: @Sendable () async -> [String]
    let spec = ToolSpec("apply_file_batch", "Apply one frozen screenshot preview after approval, revalidating every path. No overwrite or delete.", fields: ["plan": "Exact preview ID", "preview": "Human-readable move preview"], capability: .fileChanges, timeout: 30)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult { try await ScreenshotPlans.shared.apply(arguments["plan"]!.string!, preview: arguments["preview"]!.string!, roots: await roots()) }
}
struct OpenDocumentWithTool: AssistantTool {
    let spec = ToolSpec("open_document_with", "Resolve an authorized indexed file/alias and open a sole unambiguous match in the exact selected application. Never execute scripts.", fields: ["query": "File query or alias", "application": "Exact installed application"], capability: .openPath, timeout: 20)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        await AuthorizedSearch.shared.refresh()
        let items = try await AuthorizedSearch.shared.search(FileSearchQuery.parse(arguments["query"]!.string!))
        guard await AuthorizedSearch.shared.complete else { return ToolResult(false, "Indexing is incomplete. Finish indexing your authorized folders in Privacy first.") }
        guard items.count == 1, let item = items.first else { return ToolResult(false, items.isEmpty ? "No authorized indexed match. Add its folder in Privacy or remember the file as your CV." : "Choose the intended document; nothing opened.", items: items.map { ResultItem(name: $0.name, path: $0.path, kind: "document-with:" + arguments["application"]!.string!) }) }
        return try await Self.open(path: item.path, application: arguments["application"]!.string!)
    }
    static func open(path rawPath: String, application: String) async throws -> ToolResult {
        let path = URL(fileURLWithPath: LocalPath.canonical(rawPath))
        guard await AuthorizedSearch.shared.roots().contains(where: { path.path.hasPrefix($0.path + "/") }) else { return ToolResult(false, "Document folder access was revoked. Nothing opened.") }
        guard !["app", "command", "sh", "py", "js", "scpt", "workflow", "pkg"].contains(path.pathExtension.lowercased()) else { return ToolResult(false, "Executable content cannot be opened through this document workflow.") }
        guard let type = UTType(filenameExtension: path.pathExtension), type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .image), FileManager.default.isReadableFile(atPath: path.path), (try path.resourceValues(forKeys: [.isExecutableKey])).isExecutable != true else { return ToolResult(false, "The result is not a readable, non-executable supported document.") }
        let apps = try await OpenApplicationTool.resolve(application)
        guard apps.count == 1, let app = apps.first else { return ToolResult(false, "Choose one exact installed application.", items: apps) }
        return try await NativeWorkspaceOpen.openDocument(path, application: URL(fileURLWithPath: app.path), displayName: app.name)
    }
}
struct LatestPythonProjectTool: AssistantTool {
    let spec = ToolSpec("latest_python_project", "Resolve the uniquely most recent Python project in completely indexed authorized folders, then open in VS Code. Equal dates require a choice.", capability: .openPath, timeout: 20)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        await AuthorizedSearch.shared.refresh()
        let items = await AuthorizedSearch.shared.projects()
        guard await AuthorizedSearch.shared.complete, let first = items.first else { return ToolResult(false, "Add and fully index your project folders in Privacy first.", items: items) }
        guard items.count == 1 || first.modifiedAt != items[1].modifiedAt else { return ToolResult(false, "Several projects are equally recent. Choose one.", items: items) }
        return try await OpenProjectTool().execute(arguments: ["path": .string(first.path)])
    }
}

struct OpenSelectedDocumentWithTool: AssistantTool {
    let spec = ToolSpec("open_selected_document_with", "Open an explicitly selected authorized document in the requested application.", fields: ["path": "Absolute document path", "application": "Exact application"], capability: .openPath)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult { try await OpenDocumentWithTool.open(path: arguments["path"]!.string!, application: arguments["application"]!.string!) }
}
