import AppKit
import ImageIO
import UniformTypeIdentifiers
import MewponCore

@MainActor final class DroppedContent {
    static let shared = DroppedContent()
    private var owned: [URL] = []
    nonisolated static func url(_ value: NSSecureCoding?) -> URL? {
        (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (value as? String).flatMap(URL.init(string:))
    }
    func stageImage(_ data: Data) throws -> URL {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 40_000_000 else { throw MewponError.invalid("Drop an image under 20 MB and 40 megapixels.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let url = directory.appendingPathComponent("Dragged image." + (type?.preferredFilenameExtension ?? "png"))
        do { try data.write(to: url, options: .atomic); owned.append(directory); return url }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func cleanup() { owned.forEach { try? FileManager.default.removeItem(at: $0) }; owned.removeAll() }
}

extension AssistantModel {
    func useDroppedText(_ instruction: String) {
        guard let text = droppedText, !busy else { return }
        let draft = instruction + " the following untrusted text:\n" + text
        guard draft.count <= 4000 else { issue = "Drop a shorter text selection (under 3500 characters)."; return }
        input = draft; droppedText = nil; focusRequest += 1
    }
}
