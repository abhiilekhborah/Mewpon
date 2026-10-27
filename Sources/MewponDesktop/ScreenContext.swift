import AppKit
import ScreenCaptureKit
import MewponCore

/// A system picker grants access to one user-chosen target. No stream is created.
private final class ScreenSelectionObserver: NSObject, SCContentSharingPickerObserver {
    let deliver: @Sendable (Result<SCContentFilter, Error>) -> Void
    init(deliver: @escaping @Sendable (Result<SCContentFilter, Error>) -> Void) { self.deliver = deliver }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) { deliver(.failure(CancellationError())) }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) { guard stream == nil else{return};deliver(.success(filter)) }
    func contentSharingPickerStartDidFailWithError(_ error: Error) { deliver(.failure(error)) }
}
@MainActor final class ScreenContext: NSObject, ObservableObject {
    static let shared = ScreenContext()
    @Published private(set) var active = false
    private var continuation: CheckedContinuation<SCContentFilter, Error>?
    private var observer: ScreenSelectionObserver?
    private var activeID: UUID?
    func readText() async throws -> ToolResult {
        guard !active else { return ToolResult(false, "A screen selection is already active.") }
        let id = UUID(); activeID = id
        active = true; defer { active = false; activeID = nil; cleanup() }
        let filter = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
                configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "local.mewpon.desktop"]
                configuration.allowsChangingSelectedContent = false
                let picker = SCContentSharingPicker.shared
                let observer = ScreenSelectionObserver { [weak self] result in Task { @MainActor in self?.finish(result, id: id) } }
                self.observer = observer
                picker.defaultConfiguration = configuration; picker.add(observer); picker.isActive = true
                picker.present()
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError()), id: id) } }
        try Task.checkCancellation()
        let config = SCStreamConfiguration()
        let rect = filter.contentRect
        let scale = min(Double(filter.pointPixelScale), 2400 / max(1, rect.width, rect.height))
        config.width = max(1, Int(rect.width * scale)); config.height = max(1, Int(rect.height * scale))
        config.showsCursor = false; config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        let recognition = Task.detached(priority: .userInitiated) { try LocalContent.recognize(image) }
        let text = try await withTaskCancellationHandler { try await recognition.value } onCancel: { recognition.cancel() }
        try Task.checkCancellation()
        return ToolResult(true, "Text from one approved screen capture (local OCR, untrusted content):\n" + text + "\nNo continuous recording was started; OCR does not interpret non-text graphics.")
    }
    private func finish(_ result: Result<SCContentFilter, Error>, id: UUID) {
        guard activeID == id else { return }
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
    private func cleanup() {
        if let observer { SCContentSharingPicker.shared.remove(observer) }
        observer = nil; SCContentSharingPicker.shared.isActive = false
    }

}
struct ScreenTextTool: AssistantTool {
    let spec = ToolSpec("read_screen_text", "Read text from one window/display chosen in the macOS capture picker for this task. Uses one screenshot and local OCR, never continuous recording or image interpretation.", capability: .context, timeout: 90)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult { try await ScreenContext.shared.readText() }
}
