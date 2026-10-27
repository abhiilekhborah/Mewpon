import AppKit
import SwiftUI
import MewponCore

struct MarkdownMessage: View, Equatable {
    let text: String
    @State private var document = StreamingMarkdown()
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(document.blocks) { block in MarkdownBlockView(block: block).equatable() }
        }.frame(maxWidth: .infinity, alignment: .leading).font(MewponDesign.body).textSelection(.enabled)
         .onAppear { document.update(text) }.onChange(of: text) { _, value in document.update(value) }
    }
}

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.block == rhs.block }
    @ViewBuilder var body: some View {
        switch block.kind {
        case .paragraph(let text): inline(text).lineSpacing(4)
        case .heading(let level, let text): inline(text).font(.system(size: level == 1 ? 21 : level == 2 ? 18 : 15, weight: .semibold)).padding(.top, 3)
        case .list(let marker, let text): HStack(alignment: .top, spacing: 9) { Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing); inline(text) }
        case .quote(let text): HStack(spacing: 10) { Capsule().fill(MewponDesign.accent.opacity(0.5)).frame(width: 2); inline(text).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
        case .rule: Divider().padding(.vertical, 4)
        case .code(let language, let code): CodeBlockView(language: language, code: code)
        case .table(let headers, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                    GridRow { ForEach(Array(headers.enumerated()), id: \.offset) { _, header in inline(header).fontWeight(.semibold) } }
                    Divider().gridCellColumns(max(1, headers.count))
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(headers.enumerated()), id: \.offset) { index, _ in inline(index < row.count ? row[index] : "") } }
                    }
                }.padding(12)
            }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func inline(_ value: String) -> Text {
        var attributed = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        for run in attributed.runs {
            if let link = run.link, !["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { attributed[run.range].link = nil }
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: 12, design: .monospaced)
                attributed[run.range].backgroundColor = .primary.opacity(0.065)
            }
        }
        return Text(attributed)
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Plain text" : language)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string); copied = true
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.plain).help("Copy code without executing it")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 9)
            Divider().opacity(0.5)
            ScrollView(.horizontal) {
                Text(highlight(code)).font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(12)
            }
        }.background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
         .onChange(of: code) { _, _ in copied = false }
    }
    private static let lexicalRegex = try? NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|\b(func|let|var|const|class|struct|enum|return|if|else|for|while|import|from|def|async|await|throw|try|true|false|nil|None)\b|\b\d+(?:\.\d+)?\b"#)
    private func highlight(_ source: String) -> AttributedString {
        // Small native lexical highlighter, no HTML, scripts, or webview.
        var result = AttributedString(source)
        guard let regex = Self.lexicalRegex else { return result }
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source), let a = AttributedString.Index(range.lowerBound, within: result), let b = AttributedString.Index(range.upperBound, within: result) else { continue }
            let stringColor: Color = scheme == .dark ? Color(red: 0.55, green: 0.82, blue: 0.62) : Color(red: 0.12, green: 0.42, blue: 0.24)
            let keywordColor: Color = scheme == .dark ? Color(red: 0.53, green: 0.76, blue: 0.96) : Color(red: 0.08, green: 0.32, blue: 0.66)
            let numberColor: Color = scheme == .dark ? .orange : Color(red: 0.58, green: 0.30, blue: 0.08)
            result[a..<b].foregroundColor = match.range(at: 1).location != NSNotFound ? stringColor : match.range(at: 2).location != NSNotFound ? keywordColor : numberColor
        }
        return result
    }
}
