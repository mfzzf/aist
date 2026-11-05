import AistAI
import AistAgent
import SwiftUI

/// Transcript rows: a user message, or everything the assistant did in reply (several model turns
/// with tool calls in between) folded into one column.
struct TranscriptRow: Identifiable {
    enum Kind {
        case user(UserMessage)
        case assistant([AssistantMessage], results: [String: ToolResultMessage], live: Bool)
    }

    var id: Int
    var kind: Kind

    static func build(_ messages: [Message], streaming: AssistantMessage?, running: Bool) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var turn: [AssistantMessage] = []
        var results: [String: ToolResultMessage] = [:]
        var turnStart = 0
        func flush(live: Bool) {
            guard !turn.isEmpty || live else { return }
            rows.append(TranscriptRow(id: turnStart, kind: .assistant(turn, results: results, live: live)))
            turn = []
            results = [:]
        }
        for (i, m) in messages.enumerated() {
            switch m {
            case let .user(u):
                flush(live: false)
                rows.append(TranscriptRow(id: i, kind: .user(u)))
                turnStart = i + 1
            case let .assistant(a): turn.append(a)
            case let .toolResult(r): results[r.toolCallId] = r
            }
        }
        if let streaming { turn.append(streaming) }
        flush(live: running)
        return rows
    }
}

struct UserBubble: View {
    let message: UserMessage
    var compact: Bool

    var body: some View {
        HStack {
            Spacer(minLength: compact ? 24 : 80)
            Text(AgentSession.plain(message))
                .font(compact ? .callout : .body)
                .textSelection(.enabled)
                .padding(.horizontal, compact ? 10 : 13)
                .padding(.vertical, compact ? 6 : 8)
                .background(.quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
        }
    }
}

struct AssistantTurn: View {
    let messages: [AssistantMessage]
    let results: [String: ToolResultMessage]
    let live: Bool
    let runningTools: Set<String>
    var compact: Bool
    var isLast: Bool
    var onRetry: (() -> Void)?

    var body: some View {
        let parts = parts
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ForEach(Array(displayed(parts).enumerated()), id: \.offset) { _, item in
                switch item {
                case let .part(part): partView(part)
                case let .activity(steps): ActivitySummary(parts: steps, compact: compact) { partView($0) }
                }
            }
            if live, !Self.hasVisibleProgress(parts) {
                ShimmerText("思考中…", font: compact ? .caption : .callout)
            }
            if let failed = messages.last, !live {
                if failed.stopReason == .error {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(failed.errorMessage ?? "出错了").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.callout)
                } else if failed.stopReason == .aborted {
                    Text("已停止").font(.caption).foregroundStyle(.tertiary)
                } else if failed.stopReason == .length {
                    Text("回答达到长度上限，被截断了").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if !live {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Parts

    enum Part {
        /// `live`: the text still streaming in (revealed smoothly).
        case text(String, live: Bool = false)
        case thinking(String, live: Bool)
        case step(Step)
    }

    private var parts: [Part] {
        Self.parts(messages: messages, results: results, live: live, runningTools: runningTools)
    }

    static func parts(messages: [AssistantMessage], results: [String: ToolResultMessage],
                      live: Bool, runningTools: Set<String>) -> [Part] {
        var out: [Part] = []
        for (mi, m) in messages.enumerated() {
            for (ci, c) in m.content.enumerated() {
                let tail = live && mi == messages.count - 1 && ci == m.content.count - 1
                switch c {
                case let .text(t) where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    out.append(.text(t, live: tail))
                case let .thinking(t, _) where !t.isEmpty:
                    out.append(.thinking(t, live: tail))
                case let .hosted(h):
                    out.append(.step(Step(hosted: h, live: live)))
                case let .toolCall(call):
                    let result = results[call.id]
                    let running = runningTools.contains(call.id) || (live && result == nil)
                    out.append(.step(Step(call: call, result: result, running: running)))
                default: break
                }
            }
        }
        return out
    }

    enum Displayed {
        case part(Part)
        /// Finished steps folded into one line.
        case activity([Part])
    }

    /// While answering, every step shows; once done, the steps fold into one summary line where
    /// the first of them was.
    private func displayed(_ all: [Part]) -> [Displayed] { Self.displayed(all, live: live) }

    static func displayed(_ all: [Part], live: Bool) -> [Displayed] {
        guard !live else { return all.map { .part($0) } }
        let steps = all.filter { if case .text = $0 { false } else { true } }
        // Only thinking: it already is one folded line, folding it again would nest "思考过程" twice.
        let onlyThinking = steps.allSatisfy { if case .thinking = $0 { true } else { false } }
        guard !steps.isEmpty, !onlyThinking else { return all.map { .part($0) } }
        var out: [Displayed] = []
        var placed = false
        for p in all {
            if case .text = p { out.append(.part(p)) }
            else if !placed { out.append(.activity(steps)); placed = true }
        }
        return out
    }

    static func hasVisibleProgress(_ parts: [Part]) -> Bool {
        guard let last = parts.last else { return false }
        switch last {
        case .text: return true
        case let .thinking(_, live): return live
        case let .step(s): return s.running
        }
    }

    @ViewBuilder private func partView(_ part: Part) -> some View {
        switch part {
        case let .text(t, live):
            if live { StreamingMarkdown(text: t, compact: compact) } else { MarkdownText(t, compact: compact) }
        case let .thinking(t, live): ThinkingRow(text: t, live: live, compact: compact)
        case let .step(s): StepRow(step: s, compact: compact)
        }
    }

    // MARK: Footer

    private var sources: [WebSource] { Self.sources(messages: messages, results: results) }

    /// Sites behind the answer: hosted-search hits and pages fetched, one per host.
    static func sources(messages: [AssistantMessage], results: [String: ToolResultMessage]) -> [WebSource] {
        var seen = Set<String>()
        var out: [WebSource] = []
        for m in messages {
            for c in m.content {
                if case let .hosted(h) = c { out += h.sources }
                // Pages actually read; search hits stay in their step row.
                if case let .toolCall(call) = c, call.name == "fetch_page", let r = results[call.id], !r.isError {
                    out += WebTools.sources(in: r.details)
                }
            }
        }
        return out.filter { seen.insert($0.host).inserted }
    }

    static func answerText(_ messages: [AssistantMessage]) -> String {
        messages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private var footer: some View {
        AssistantFooter(sources: sources, answerText: Self.answerText(messages), isLast: isLast,
                        model: messages.last.flatMap { $0.usage.output > 0 && !compact ? $0.model : nil },
                        compact: compact, onRetry: onRetry)
    }
}

/// Under a finished answer: the sources pill, copy, retry and the model that answered.
struct AssistantFooter: View {
    let sources: [WebSource]
    let answerText: String
    let isLast: Bool
    let model: String?
    var compact: Bool
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            if !sources.isEmpty { SourcesPill(sources: sources) }
            if !answerText.isEmpty || onRetry != nil {
                HStack(spacing: 2) {
                    if !answerText.isEmpty {
                        CopyButton(text: answerText)
                    }
                    if isLast, let onRetry {
                        Button(action: onRetry) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("重新回答")
                    }
                    if let model {
                        Text(model)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 6)
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// "已搜索 2 次，阅读了 3 个网页 ›" — expands to the individual steps.
struct ActivitySummary<Row: View>: View {
    let parts: [AssistantTurn.Part]
    var compact: Bool
    @ViewBuilder var row: (AssistantTurn.Part) -> Row
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    if hosts.isEmpty {
                        Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                    } else {
                        HStack(spacing: -4) {
                            ForEach(hosts.prefix(3), id: \.self) { h in
                                Favicon(host: h, size: 14)
                                    .padding(1)
                                    .background(Circle().fill(.background))
                                    .clipShape(Circle())
                            }
                        }
                    }
                    Text(summary).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.snappy(duration: 0.2), value: expanded)
                }
                .font(compact ? .caption : .callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in row(p) }
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 1).offset(x: -1)
                }
            }
        }
    }

    /// Sites seen in these steps, pages read first.
    private var hosts: [String] {
        var seen = Set<String>()
        var reads: [String] = [], found: [String] = []
        for case let .step(step) in parts {
            for src in step.sources where seen.insert(src.host).inserted {
                if step.icon == "doc.text" { reads.append(src.host) } else { found.append(src.host) }
            }
        }
        return reads + found
    }

    private var counts: (search: Int, read: Int, think: Bool, failed: Int) {
        var s = 0, r = 0, f = 0, t = false
        for p in parts {
            switch p {
            case let .step(step):
                if step.icon == "magnifyingglass" { s += 1 } else if step.icon == "doc.text" { r += 1 }
                if step.error != nil { f += 1 }
            case .thinking: t = true
            case .text: break
            }
        }
        return (s, r, t, f)
    }

    private var summary: String {
        let c = counts
        var bits: [String] = []
        if c.search > 0 { bits.append("搜索了 \(c.search) 次") }
        if c.read > 0 { bits.append("阅读了 \(c.read) 个网页") }
        let others = parts.count - c.search - c.read - (c.think ? 1 : 0)
        if others > 0 { bits.append("调用了 \(others) 个工具") }
        if bits.isEmpty { return c.think ? "思考过程" : "过程" }
        return (c.think ? "思考后" : "") + bits.joined(separator: "，")
    }

    private var icon: String {
        let c = counts
        return c.search > 0 ? "globe" : c.read > 0 ? "doc.text" : c.think ? "brain" : "wrench.and.screwdriver"
    }
}

/// "来源" with the first few site icons overlapping; opens a list with icons and titles.
struct SourcesPill: View {
    let sources: [WebSource]
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                HStack(spacing: -5) {
                    ForEach(sources.prefix(4)) { s in
                        Favicon(host: s.host, size: 16)
                            .padding(1.5)
                            .background(Circle().fill(.background))
                            .clipShape(Circle())
                    }
                }
                Text("\(sources.count) 个来源").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sources) { s in SourceRow(source: s) }
                }
                .padding(8)
            }
            .frame(width: 360)
            .frame(maxHeight: 420)
        }
    }
}

struct SourceRow: View {
    let source: WebSource
    @State private var hovering = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: source.url) { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Favicon(host: source.host, size: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).lineLimit(2).foregroundStyle(.primary)
                    Text(source.host).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.url)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .help("复制回答")
    }
}

// MARK: - Steps

struct Step {
    var icon: String
    var running: Bool
    var title: String
    var sources: [WebSource]
    var error: String?

    init(hosted h: HostedBlock, live: Bool) {
        let running = !h.done && live
        icon = h.tool == .webSearch ? "magnifyingglass" : "doc.text"
        self.running = running
        let q = h.detail
        switch h.tool {
        case .webSearch: title = running ? "正在搜索 “\(q)”" : "搜索了 “\(q)”"
        case .webFetch: title = running ? "正在阅读 \(Self.host(q))" : "阅读了 \(Self.host(q))"
        }
        sources = h.sources
        error = h.error
    }

    init(call: ToolCall, result: ToolResultMessage?, running: Bool) {
        self.running = running
        sources = WebTools.sources(in: result?.details)
        error = result?.isError == true ? result?.text : nil
        switch call.name {
        case "web_search":
            let q = call.arguments["query"]?.stringValue ?? ""
            icon = "magnifyingglass"
            title = running ? "正在搜索 “\(q)”" : "搜索了 “\(q)”"
        case "fetch_page":
            let u = Self.host(call.arguments["url"]?.stringValue ?? "")
            icon = "doc.text"
            title = running ? "正在阅读 \(u)" : "阅读了 \(u)"
        default:
            icon = "wrench.and.screwdriver"
            title = running ? "正在调用 \(call.name)" : "调用了 \(call.name)"
        }
    }

    static func host(_ s: String) -> String {
        WebSource(url: s, title: s).host
    }
}

struct StepRow: View {
    let step: Step
    var compact: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: step.error != nil ? "exclamationmark.circle" : step.icon)
                        .foregroundStyle(step.error != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                    if step.running {
                        ShimmerText(step.title, font: compact ? .caption : .callout)
                    } else {
                        Text(step.title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if step.icon == "magnifyingglass", !step.sources.isEmpty {
                            Text("· \(step.sources.count) 个结果").foregroundStyle(.tertiary)
                        }
                        if canExpand {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .animation(.snappy(duration: 0.2), value: expanded)
                        }
                    }
                }
                .font(compact ? .caption : .callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    if let error = step.error {
                        Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ForEach(step.sources.prefix(10)) { s in
                        if let url = URL(string: s.url) {
                            Link(destination: url) {
                                HStack(spacing: 6) {
                                    Favicon(host: s.host, size: 13)
                                    Text(s.title).lineLimit(1)
                                    Text(s.host).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                            .help(s.url)
                        }
                    }
                }
                .font(.caption)
                .padding(.leading, 22)
            }
        }
    }

    private var canExpand: Bool { !step.running && (!step.sources.isEmpty || step.error != nil) }
}

struct ThinkingRow: View {
    let text: String
    let live: Bool
    var compact: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").foregroundStyle(.secondary).frame(width: 16)
                    if live {
                        ShimmerText("思考中…", font: compact ? .caption : .callout)
                    } else {
                        Text("思考过程").foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.snappy(duration: 0.2), value: expanded)
                }
                .font(compact ? .caption : .callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
    }
}

// MARK: - Sources

/// Wraps children onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
