import AppKit
import MewponCore

/// Discrete layout decisions keep token updates from resizing the window continuously.
enum PalettePresentation: Equatable {
    case idle, suggestions(Int), files(Int), working, confirmation, response(Int)
    static let commands = ["Open Safari", "Open Downloads", "Find my CV", "Search recent PDFs", "What's my battery?", "What time is it?"]
    static func suggestions(for input: String) -> [String] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return commands.filter { $0.localizedCaseInsensitiveContains(query) && $0.caseInsensitiveCompare(query) != .orderedSame }
    }
    static func currentTurn(_ entries: [ChatEntry]) -> [ChatEntry] {
        Array(entries.suffix(from: entries.lastIndex(where: { $0.role == "user" }) ?? entries.startIndex))
    }
    static func resolve(input: String, entries: [ChatEntry], busy: Bool, history: Bool = false) -> Self {
        let suggestions = suggestions(for: input)
        if !busy, !suggestions.isEmpty { return .suggestions(suggestions.count) }
        let turn = currentTurn(entries)
        if let result = turn.last(where: { $0.result != nil })?.result, !result.items.isEmpty { return .files(result.items.count) }
        if busy, !turn.contains(where: { $0.role == "assistant" && !$0.text.isEmpty }) { return .working }
        if !history, let result = turn.last(where: { $0.result != nil })?.result,
           turn.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) == result.summary.trimmingCharacters(in: .whitespacesAndNewlines) || turn.last?.result != nil {
            if result.summary.count<=140,!result.summary.contains("\n"){return .confirmation}
            return .response(min(6,max(0,result.summary.count/240)))
        }
        if entries.isEmpty { return .idle }
        let text = (history ? entries : turn).filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n")
        if busy, text.isEmpty { return .working }
        return .response(min(6, max(0, text.count / 240)))
    }
    var height: CGFloat {
        switch self {
        case .idle: return 80
        case .suggestions(let count): return 112 + CGFloat(min(count, 5)) * 38
        case .files(let count): return 160 + CGFloat(min(count, 6)) * 53
        case .working: return 132
        case .confirmation: return 158
        case .response(let bucket): return min(568, 260 + CGFloat(bucket) * 48)
        }
    }
    var expanded: Bool { self != .idle }
}
