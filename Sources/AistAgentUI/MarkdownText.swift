import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Markdown as native SwiftUI: block structure parsed here (headings, lists, quotes, code, tables),
/// inline styling (bold, italics, `code`, links) by Foundation's parser. Tolerates half-streamed input.
public struct MarkdownText: View {
    let text: String
    var compact: Bool
    /// Still growing: only the last block changes, so only it is parsed fresh (and not cached).
    var streaming: Bool

    public init(_ text: String, compact: Bool = false, streaming: Bool = false) {
        self.text = text
        self.compact = compact
        self.streaming = streaming
    }

    public var body: some View {
        let blocks = streaming ? MarkdownBlocks.parse(text) : MarkdownCache.blocks(text)
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                // Equatable: finished blocks are skipped on every streaming frame.
                MarkdownBlockView(block: block, compact: compact, cache: !streaming || i < blocks.count - 1)
                    .equatable()
            }
        }
        .font(compact ? .callout : .body)
        .lineSpacing(compact ? 1 : 3)
        // No per-Text selection: on macOS it gives every Text an AppKit interaction view with its
        // own TextKit layout pass, which was a third of the cost of showing a conversation.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlocks.Block
    let compact: Bool
    /// False for the block still streaming in: its every prefix would only fill the cache.
    let cache: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.block == b.block && a.compact == b.compact && a.cache == b.cache
    }

    var body: some View {
        // Only blocks with web links watch the icon store; the rest must not re-layout as icons arrive.
        if block.mayHaveLinks {
            LinkedBlockView(block: block, compact: compact, cache: cache)
        } else {
            BlockBody(block: block, compact: compact, cache: cache, icons: nil)
        }
    }
}

private struct LinkedBlockView: View {
    let block: MarkdownBlocks.Block
    let compact: Bool
    let cache: Bool
    @ObservedObject private var icons = FaviconStore.shared

    init(block: MarkdownBlocks.Block, compact: Bool, cache: Bool) {
        self.block = block
        self.compact = compact
        self.cache = cache
    }

    var body: some View { BlockBody(block: block, compact: compact, cache: cache, icons: icons) }
}

private struct BlockBody: View {
    let block: MarkdownBlocks.Block
    let compact: Bool
    let cache: Bool
    let icons: FaviconStore?

    var body: some View { view(block) }
    @ViewBuilder private func view(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case let .heading(level, s):
            rich(s)
                .font(level <= 2 ? (compact ? .headline : .title3) : (compact ? .subheadline : .headline))
                .fontWeight(.semibold)
                .padding(.top, compact ? 2 : 4)
        case let .paragraph(s):
            rich(s).frame(maxWidth: .infinity, alignment: .leading)
        case let .list(items):
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 14, alignment: .trailing)
                        rich(item.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }
        case let .quote(s):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                rich(s).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .code(lang, code):
            CodeBlock(language: lang, code: code, compact: compact)
        case let .table(header, rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Divider()
        }
    }

    /// Inline markdown with each web link led by its site's icon, the way citations read in ChatGPT.
    private func rich(_ s: String) -> Text {
        let attr = cache ? MarkdownCache.inline(s) : (MarkdownCache.cached(s) ?? MarkdownText.inline(s))
        guard attr.runs.contains(where: { $0.link != nil }) else { return Text(attr) }
        var out = Text("")
        var previous: URL?
        for run in attr.runs {
            let piece = Text(AttributedString(attr[run.range]))
            if let link = run.link, link != previous, let host = link.host, link.scheme?.hasPrefix("http") == true {
                let key = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                if let icon = icons?.image(for: key) {
                    #if os(macOS)
                    let image = Text(Image(nsImage: icon)).baselineOffset(-2)
                    #else
                    let image = Text(Image(uiImage: icon)).baselineOffset(-2)
                    #endif
                    out = Text("\(out)\(image) \(piece)")
                } else {
                    out = Text("\(out)\(piece)")
                }
            } else {
                out = Text("\(out)\(piece)")
            }
            previous = run.link
        }
        return out
    }

}

extension MarkdownText {
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: escapeTildes(s), options: .init(
            allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        ))) ?? AttributedString(s)
    }
}

/// Parsed blocks and inline strings by text, so redraws (streaming, favicons arriving, switching
/// conversations) don't re-parse unchanged messages.
@MainActor
enum MarkdownCache {
    private static var blockCache: [String: [MarkdownBlocks.Block]] = [:]
    private static var inlineCache: [String: AttributedString] = [:]

    static func blocks(_ text: String) -> [MarkdownBlocks.Block] {
        if let b = blockCache[text] { return b }
        let b = MarkdownBlocks.parse(text)
        if blockCache.count > 400 { blockCache.removeAll(keepingCapacity: true) }
        blockCache[text] = b
        return b
    }

    static func cached(_ s: String) -> AttributedString? { inlineCache[s] }

    static func inline(_ s: String) -> AttributedString {
        if let a = inlineCache[s] { return a }
        let a = MarkdownText.inline(s)
        if inlineCache.count > 4000 { inlineCache.removeAll(keepingCapacity: true) }
        inlineCache[s] = a
        return a
    }
}

extension MarkdownText {
    /// A single `~` is a range in Chinese ("30~32°C"), not strikethrough; only `~~` strikes.
    /// Code spans are left alone.
    static func escapeTildes(_ s: String) -> String {
        guard s.contains("~") else { return s }
        let parts = s.components(separatedBy: "`")
        return parts.enumerated().map { i, part in
            guard i % 2 == 0, part.contains("~") else { return part }
            return part.replacingOccurrences(of: #"(?<![~\\])~(?!~)"#, with: #"\\~"#, options: .regularExpression)
        }.joined(separator: "`")
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    var compact: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Pasteboard.copy(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("复制代码")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(compact ? .caption : .callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }
}

struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                        Text(MarkdownCache.inline(h)).fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow(alignment: .top) {
                        ForEach(0..<header.count, id: \.self) { i in
                            Text(MarkdownCache.inline(i < row.count ? row[i] : ""))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
        }
        .padding(.vertical, 4)
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}

/// Line-based block parser. Unclosed code fences (mid-stream) run to the end.
enum MarkdownBlocks {
    struct Item: Hashable {
        var level: Int
        var marker: String
        var text: String
    }

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case list([Item])
        case quote(String)
        case code(String, String)
        case table([String], [[String]])
        case rule

        /// Cheap test for inline web links (a false positive only costs an observer).
        var mayHaveLinks: Bool {
            switch self {
            case let .heading(_, s), let .paragraph(s), let .quote(s): return s.contains("http")
            case let .list(items): return items.contains { $0.text.contains("http") }
            case .code, .table, .rule: return false
            }
        }
    }

    static func parse(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var para: [String] = []
        var items: [Item] = []
        var quote: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang, code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            if let level = heading(trimmed) {
                flush()
                blocks.append(.heading(level, String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1, "-*_".contains(trimmed.first!) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(header, rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                if !para.isEmpty || !items.isEmpty { let q = quote; flush(); quote = q }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            if let item = listItem(line) {
                if !para.isEmpty || !quote.isEmpty { let it = items; flush(); items = it }
                items.append(item)
                i += 1
                continue
            }
            if !items.isEmpty, line.hasPrefix("  ") {
                // Continuation of a list item.
                items[items.count - 1].text += "\n" + trimmed
                i += 1
                continue
            }
            if !items.isEmpty || !quote.isEmpty { flush() }
            para.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    private static func heading(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> Item? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let s = line.trimmingCharacters(in: .whitespaces)
        let level = min(indent / 2, 4)
        for bullet in ["- ", "* ", "+ "] where s.hasPrefix(bullet) {
            var text = String(s.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text = String(text.dropFirst(4)) }
            return Item(level: level, marker: level > 0 && marker == "•" ? "◦" : marker, text: text)
        }
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return Item(level: level, marker: digits + ".", text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isSeparator(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("|") && s.contains("-") && s.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var s = Substring(row)
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") { s = s.dropLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
