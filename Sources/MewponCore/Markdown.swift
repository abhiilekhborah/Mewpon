import Foundation

public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph(String), heading(Int, String), list(String, String), quote(String)
        case code(String, String), table([String], [[String]]), rule
    }
    public let id: Int
    public let kind: Kind
    public init(id: Int, kind: Kind) { self.id = id; self.kind = kind }
}

public enum MarkdownParser {
    public static func parse(_ source: String, lineOffset: Int = 0) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = [], index = 0
        func cells(_ line: String) -> [String] {
            var values = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if values.first == "" { values.removeFirst() }; if values.last == "" { values.removeLast() }
            return values
        }
        func tableSeparator(_ line: String) -> Bool {
            let values = cells(line)
            return !values.isEmpty && values.allSatisfy { $0.replacingOccurrences(of: ":", with: "").filter { !$0.isWhitespace }.count >= 3 && $0.allSatisfy { $0 == "-" || $0 == ":" || $0.isWhitespace } }
        }
        func marker(_ line: String) -> (String, String)? {
            for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) { return ("•", String(line.dropFirst(2))) }
            if let range = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                return (String(line[range]).trimmingCharacters(in: .whitespaces), String(line[range.upperBound...]))
            }
            return nil
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces), start = index
            if trimmed.isEmpty { index += 1; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3)), language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1; var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[index]); index += 1 }
                if index < lines.count { index += 1 }
                blocks.append(.init(id: start + lineOffset, kind: .code(language, code.joined(separator: "\n")))); continue
            }
            if index + 1 < lines.count, line.contains("|"), tableSeparator(lines[index + 1]) {
                let headers = cells(line); index += 2; var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index])); index += 1
                }
                blocks.append(.init(id: start + lineOffset, kind: .table(headers, rows))); continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { blocks.append(.init(id: start + lineOffset, kind: .rule)); index += 1; continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                blocks.append(.init(id: start + lineOffset, kind: .heading(hashes, String(trimmed.dropFirst(hashes + 1))))); index += 1; continue
            }
            if let (bullet, text) = marker(trimmed) { blocks.append(.init(id: start + lineOffset, kind: .list(bullet, text))); index += 1; continue }
            if trimmed.hasPrefix("> ") { blocks.append(.init(id: start + lineOffset, kind: .quote(String(trimmed.dropFirst(2))))); index += 1; continue }
            var paragraph = [line]; index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("```") || next.hasPrefix("~~~") || next.hasPrefix("#") || next.hasPrefix("> ") || marker(next) != nil || next == "---" { break }
                if index + 1 < lines.count, lines[index].contains("|"), tableSeparator(lines[index + 1]) { break }
                paragraph.append(lines[index]); index += 1
            }
            blocks.append(.init(id: start + lineOffset, kind: .paragraph(paragraph.joined(separator: "\n"))))
        }
        return blocks
    }
}

/// Reparse only the mutable tail while preserving the identities of completed blocks.
public struct StreamingMarkdown: Sendable {
    public private(set) var blocks: [MarkdownBlock] = []
    private var previous = ""
    public init() {}
    public mutating func update(_ text: String) {
        guard text != previous else { return }
        if text.hasPrefix(previous), blocks.count > 2 {
            let tail = blocks[blocks.count - 2].id
            let lines = text.components(separatedBy: "\n")
            blocks.removeLast(2)
            blocks += MarkdownParser.parse(lines.dropFirst(tail).joined(separator: "\n"), lineOffset: tail)
        } else { blocks = MarkdownParser.parse(text) }
        previous = text
    }
}
