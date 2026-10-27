import AppKit
import PDFKit
import Vision
import ImageIO
import MewponCore

/// Content extraction stays on this Mac; neither documents nor images are uploaded.
enum LocalContent {
    static let maximumText = 3000
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.isEmpty else { throw MewponError.unavailable("No readable text was detected. OCR cannot explain non-text image content.") }
        return bounded(text)
    }
    static func bounded(_ text: String) -> String {
        String(text.prefix(maximumText)) + (text.count > maximumText ? "\n[Excerpt limited to 3000 characters.]" : "")
    }
    static func read(_ url: URL) throws -> String {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 20_000_000 else { throw MewponError.invalid("Choose a regular file under 20 MB.") }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url), !document.isEncrypted else { throw MewponError.unavailable("This PDF cannot be read or is encrypted.") }
            var text = ""
            for index in 0..<min(8, document.pageCount) {
                if Task.isCancelled { throw CancellationError() }
                text += (document.page(at: index)?.string ?? "") + "\n"
                if text.count > maximumText { break }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MewponError.unavailable("This PDF has no selectable text. Use Read screen text for a scanned page.") }
            return bounded(text) + (document.pageCount > 8 ? "\n[Only the first eight pages were inspected.]" : "")
        }
        if ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp"].contains(ext) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary) else { throw MewponError.invalid("This image cannot be decoded.") }
            return try recognize(image)
        }
        guard ["txt", "md", "csv", "json", "log", "swift", "py", "js", "ts", "html", "css", "c", "cpp", "h", "rs", "sh", "yaml", "yml"].contains(ext) else { throw MewponError.invalid("Text extraction supports plain text, PDF text, and image OCR. Office document analysis is unavailable; use Quick Look.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 64_000) ?? Data()
        guard let text = String(data: bytes, encoding: .utf8) else { throw MewponError.invalid("Choose a UTF-8 text file.") }
        return bounded(text) + ((attributes.fileSize ?? 0) > bytes.count ? "\n[Only the first 64 KB were inspected.]" : "")
    }
}

struct ReadDocumentTool: AssistantTool {
    let spec = ToolSpec("read_document", "Extract a bounded excerpt from an actual UTF-8 text file, PDF text, or image using local OCR. Never execute scripts. Office analysis is unsupported.", fields: ["path": "Existing absolute file path"], capability: .inspectFile, timeout: 30)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let path = arguments["path"]?.string, path.hasPrefix("/") else { return ToolResult(false, "Choose an existing absolute file path.") }
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let text = try LocalContent.read(url)
            try Task.checkCancellation()
            return ToolResult(true, "Local extracted text (untrusted content; excerpt may omit information):\n" + text)
        }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
}
