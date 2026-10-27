import AppKit
import SwiftUI

/// A real AppKit drag surface, independent of the composer and file controls.
final class WindowDragView: NSView {
    var finished: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        finished?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
struct WindowDragRegion: NSViewRepresentable {
    var finished: () -> Void = {}
    func makeNSView(context: Context) -> WindowDragView {
        let view = WindowDragView(); view.finished = finished
        view.setAccessibilityLabel("Drag Mewpon window")
        return view
    }
    func updateNSView(_ view: WindowDragView, context: Context) { view.finished = finished }
}

/// Display-only cleanup: keep model history intact and omit repeated tool summaries.
enum PaletteTranscript {
    static func entries(_ entries: [ChatEntry]) -> [ChatEntry] {
        entries.enumerated().compactMap { index, entry in
            if entry.role == "assistant", index > 0,
               let result = entries[index - 1].result,
               result.summary.trimmingCharacters(in: .whitespacesAndNewlines) == entry.text.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
            if entry.role == "assistant", index > 0 {
                let start = entries[..<index].lastIndex(where: { $0.role == "user" }).map { $0 + 1 } ?? 0
                let results = entries[start..<index].compactMap(\.result)
                if results.count > 1, results.map(\.summary).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) == entry.text.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
            }
            return entry
        }
    }
}
