#if os(macOS)
import AistAI
import AistAgent
import AppKit
import Combine
import SwiftUI
import os

/// Navigation tracing for the click/switch path (`log stream --predicate 'subsystem == "com.aist"'`).
public enum NavTrace {
    private static let logger = Logger(subsystem: "com.aist", category: "nav")
    /// Set by the host's test hooks; also appends to /tmp/aist-nav.log so a run can be read afterwards.
    nonisolated(unsafe) public static var file: FileHandle?
    public static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        if let file {
            let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
            file.write(line.data(using: .utf8)!)
        }
    }
}

/// The transcript as one TextKit 2 document in a native scroll view.
///
/// Prose (headings, paragraphs, lists, quotes) is real text: laid out once per change, selectable
/// across messages, links clickable. Everything that isn't prose — the question bubble, step rows,
/// the folded activity line, code blocks, the sources pill and footer — is a SwiftUI view embedded
/// as a text attachment, so those components stay shared with the compact pop-up. Tables are drawn
/// natively (a SwiftUI grid measured its cells many times over).
///
/// Each conversation keeps its own text view; switching back swaps it in with its layout and scroll
/// position intact. Within a conversation only changed rows are rebuilt and only the changed tail
/// of the document is replaced, so a streaming frame re-lays out a few paragraphs.
struct TranscriptTextView: NSViewRepresentable {
    typealias NSViewType = NSView
    typealias Coordinator = TranscriptCoordinator

    let rows: [TranscriptRow]
    @ObservedObject var session: AgentSession
    var compact: Bool
    var width: CGFloat?

    func makeCoordinator() -> TranscriptCoordinator { TranscriptCoordinator() }

    // Spelled out: `Context` alone would be AistAI's LLM context type.
    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSView { context.coordinator.container }

    func updateNSView(_ view: NSView, context: NSViewRepresentableContext<Self>) {
        context.coordinator.apply(rows: rows, session: session, compact: compact, column: width)
    }
}

// MARK: - Coordinator

@MainActor
final class TranscriptCoordinator: NSObject, NSTextLayoutManagerDelegate {
    /// Holds one scroll view per conversation; only the current one is visible. Hidden ones keep
    /// their layout, scroll position and insets, so switching back is a visibility toggle.
    let container = NSView()

    /// One per conversation shown in this view (the newest `recentLimit` are kept).
    private final class Document {
        let scrollView: NSScrollView
        let textView: NSTextView
        var rows: [TranscriptRow] = []
        var rendered: [RowRender] = []
        /// The question sent while this document was shown, kept at the top with room beneath.
        var pinnedQuestion: Int?
        init(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
        }
    }

    private var scrollView: NSScrollView? { current?.scrollView }

    private static let recentLimit = 12
    private var documents: [UUID?: Document] = [:]
    private var order: [UUID?] = []
    private var current: Document?
    private var currentID: UUID?

    private var style = TranscriptStyle(compact: false)
    private var openSerial = Int.min
    private var column: CGFloat?
    private weak var session: AgentSession?
    private var applying = false
    private let reveal = StreamReveal()
    private var liveOverride: String?
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        super.init()
        NavTrace.log("transcript.coordinator init")
        container.autoresizesSubviews = true
        reveal.$shown.dropFirst()
            .sink { [weak self] shown in self?.liveTextChanged(shown) }
            .store(in: &subscriptions)
        // Icons land one by one; rebuild the rows waiting for them once per burst.
        FaviconStore.shared.$images.dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] images in self?.iconsArrived(images) }
            .store(in: &subscriptions)
    }

    private func makeDocument() -> Document {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.scrollerInsets = NSEdgeInsets()
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.usesFontPanel = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 24, height: style.compact ? 10 : 24)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.textLayoutManager?.delegate = self
        scrollView.documentView = textView
        return Document(scrollView: scrollView, textView: textView)
    }

    // MARK: Documents

    private func document(for id: UUID?) -> Document {
        if let doc = documents[id] {
            order.removeAll { $0 == id }
            order.append(id)
            return doc
        }
        let doc = makeDocument()
        NavTrace.log("transcript.newDocument \(id?.uuidString.prefix(8) ?? "nil") (have \(documents.count))")
        documents[id] = doc
        order.append(id)
        if order.count > Self.recentLimit, let oldest = order.first, oldest != currentID {
            order.removeFirst()
            documents[oldest]?.scrollView.removeFromSuperview()
            documents[oldest] = nil
        }
        return doc
    }

    /// Makes `doc` the visible one. Its scroll view keeps its own position and insets.
    private func show(_ doc: Document, id: UUID?) {
        current = doc
        currentID = id
        if doc.scrollView.superview !== container {
            doc.scrollView.frame = container.bounds
            doc.scrollView.autoresizingMask = [.width, .height]
            container.addSubview(doc.scrollView)
            doc.textView.frame.size.width = doc.scrollView.contentView.bounds.width
        }
        for other in documents.values where other !== doc { other.scrollView.isHidden = true }
        doc.scrollView.isHidden = false
        centreColumn()
    }

    // MARK: Updates from SwiftUI

    func apply(rows newRows: [TranscriptRow], session: AgentSession, compact: Bool, column: CGFloat?) {
        self.session = session
        if style.compact != compact {
            style = TranscriptStyle(compact: compact)
            container.subviews.forEach { $0.removeFromSuperview() }
            documents = [:]
            order = []
            current = nil
        }
        if self.column != column {
            self.column = column
            centreColumn()
        }

        let opened = session.openSerial != openSerial
        openSerial = session.openSerial
        let id = session.conversationID
        NavTrace.log("transcript.apply serial=\(session.openSerial) opened=\(opened) id=\(id?.uuidString.prefix(8) ?? "nil") rows=\(newRows.count) cached=\(documents[id] != nil)")
        let doc: Document
        let fresh: Bool
        if let current, !opened, currentID == nil, id != nil {
            // A new conversation got its id with the first answer: same document, new key.
            documents[currentID] = nil
            order.removeAll { $0 == currentID }
            documents[id] = current
            order.append(id)
            currentID = id
            doc = current
            fresh = false
        } else if let current, !opened, currentID == id {
            doc = current
            fresh = false
        } else {
            fresh = documents[id] == nil
            doc = document(for: id)
            show(doc, id: id)
        }

        let previousQuestion = Self.lastQuestion(doc.rows)
        let question = Self.lastQuestion(newRows)
        let sent = !opened && question != previousQuestion && question != nil && session.isRunning

        applying = true
        if let live = Self.liveText(in: newRows) {
            reveal.update(live, animate: !opened && !Self.reduceMotion)
            liveOverride = reveal.shown
        } else {
            reveal.snap("")
            liveOverride = nil
        }
        let wasAtBottom = isAtBottom
        let changed = render(newRows, into: doc, session: session)
        applying = false

        if opened {
            if fresh {
                doc.pinnedQuestion = nil
                doc.scrollView.contentInsets.bottom = 0
                scrollToBottom()
            }
        } else if sent {
            doc.pinnedQuestion = question
            updateBottomInset(doc)
            scrollQuestionToTop(animated: true)
        } else if changed {
            updateBottomInset(doc)
            if wasAtBottom, doc.scrollView.contentInsets.bottom == 0 { scrollToBottom() }
        }
    }

    /// The smooth reveal advanced: only the streaming row changes.
    private func liveTextChanged(_ shown: String) {
        guard !applying, let session, let doc = current, liveOverride != nil else { return }
        liveOverride = shown
        let wasAtBottom = isAtBottom
        guard render(doc.rows, into: doc, session: session) else { return }
        updateBottomInset(doc)
        if wasAtBottom, doc.scrollView.contentInsets.bottom == 0 { scrollToBottom() }
    }

    /// Site icons loaded: rebuild the rows whose links were waiting for them.
    private func iconsArrived(_ images: [String: NSImage]) {
        guard let session, let doc = current else { return }
        var any = false
        for i in doc.rendered.indices where !doc.rendered[i].missingHosts.isDisjoint(with: images.keys) {
            doc.rendered[i].signature = .min
            any = true
        }
        guard any else { return }
        let wasAtBottom = isAtBottom
        guard render(doc.rows, into: doc, session: session) else { return }
        if wasAtBottom, doc.scrollView.contentInsets.bottom == 0 { scrollToBottom() }
    }

    /// An embedded view grew or shrank (a step row expanded): lay its paragraph out again.
    private func attachmentResized(_ attachment: ViewAttachment) {
        guard let doc = current, let storage = doc.textView.textStorage,
              let tlm = doc.textView.textLayoutManager, let tcm = doc.textView.textContentStorage else { return }
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? ViewAttachment === attachment { found = range; stop.pointee = true }
        }
        guard let found,
              let start = tcm.location(tcm.documentRange.location, offsetBy: found.location),
              let end = tcm.location(start, offsetBy: found.length),
              let range = NSTextRange(location: start, end: end) else { return }
        tlm.invalidateLayout(for: range)
        doc.textView.needsLayout = true
        doc.textView.needsDisplay = true
    }

    // MARK: Rendering

    /// Returns whether the document's text changed.
    @discardableResult
    private func render(_ newRows: [TranscriptRow], into doc: Document, session: AgentSession) -> Bool {
        let builder = RowBuilder(style: style, session: session) { [weak self] attachment in
            self?.attachmentResized(attachment)
        }
        var next: [RowRender] = []
        next.reserveCapacity(newRows.count)
        var firstChanged: Int?
        for (i, row) in newRows.enumerated() {
            let isLast = i == newRows.count - 1
            let signature = RowRender.signature(
                row, isLast: isLast, running: session.isRunning,
                runningTools: session.runningTools, liveOverride: liveOverride)
            if i < doc.rendered.count, doc.rendered[i].signature == signature {
                next.append(doc.rendered[i])
                continue
            }
            if firstChanged == nil { firstChanged = i }
            let reuse = i < doc.rendered.count ? doc.rendered[i].attachments : [:]
            next.append(builder.build(row, isLast: isLast, liveOverride: liveOverride, reuse: reuse, signature: signature))
        }
        doc.rows = newRows
        guard let storage = doc.textView.textStorage else { return false }
        if firstChanged == nil, doc.rendered.count == newRows.count { return false }
        let first = firstChanged ?? min(newRows.count, doc.rendered.count)
        let start = doc.rendered.prefix(first).reduce(0) { $0 + $1.length }
        // Within the first changed row keep what hasn't changed (a streaming frame only grows the
        // last paragraph): the embedded views before it keep their layout instead of flickering.
        var keep = 0
        if let firstChanged, firstChanged < doc.rendered.count, firstChanged < next.count {
            keep = Self.commonPrefix(doc.rendered[firstChanged].string, next[firstChanged].string)
        }
        let tail = NSMutableAttributedString()
        if keep > 0 {
            let s = next[first].string
            tail.append(s.attributedSubstring(from: NSRange(location: keep, length: s.length - keep)))
            for r in next[(first + 1)...] { tail.append(r.string) }
        } else {
            for r in next[first...] { tail.append(r.string) }
        }
        storage.replaceCharacters(in: NSRange(location: start + keep, length: storage.length - start - keep), with: tail)
        doc.rendered = next
        return true
    }

    /// Length of the shared beginning of two renderings of a row, never past the start of the old
    /// string's last paragraph (its spacing changes once another paragraph follows it), and
    /// treating embedded views as equal only when they are the same attachment object.
    private static func commonPrefix(_ old: NSAttributedString, _ new: NSAttributedString) -> Int {
        guard old.length > 0, new.length > 0 else { return 0 }
        let a = old.string as NSString, b = new.string as NSString
        let lastParagraph = a.paragraphRange(for: NSRange(location: old.length - 1, length: 0)).location
        let limit = min(lastParagraph, min(a.length, b.length))
        var i = 0
        while i < limit {
            let c = a.character(at: i)
            guard c == b.character(at: i) else { break }
            if c == 0xFFFC,
               (old.attribute(.attachment, at: i, effectiveRange: nil) as AnyObject?) !==
               (new.attribute(.attachment, at: i, effectiveRange: nil) as AnyObject?) { break }
            i += 1
        }
        // Back up to a paragraph start so no paragraph is left half old, half new.
        return i == 0 ? 0 : a.paragraphRange(for: NSRange(location: i, length: 0)).location
    }

    // MARK: Geometry

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var viewportHeight: CGFloat { scrollView?.contentView.bounds.height ?? 0 }

    private var isAtBottom: Bool {
        guard let scrollView, let doc = scrollView.documentView else { return true }
        let visible = scrollView.contentView.bounds
        return visible.maxY >= doc.frame.height + scrollView.contentInsets.bottom - 40
    }

    @objc private func viewportChanged() {
        centreColumn()
        if let doc = current { updateBottomInset(doc) }
    }

    /// The text column is centred and at most `column` wide (the pop-up uses the full width).
    private func centreColumn() {
        guard let current else { return }
        let textView = current.textView
        let width = current.scrollView.contentView.bounds.width
        let side: CGFloat = style.compact ? 12 : 24
        let inset = column.map { max(side, (width - $0) / 2) } ?? side
        if abs(textView.textContainerInset.width - inset) > 0.5 {
            textView.textContainerInset = NSSize(width: inset, height: style.compact ? 10 : 24)
        }
    }

    /// Scrolls to the end using TextKit 2's estimate of the document height: only the last
    /// screenful is laid out for real, the rest when (if) the user scrolls up.
    private func scrollToBottom() {
        NavTrace.log("transcript.scrollToBottom")
        guard let current, let tlm = current.textView.textLayoutManager,
              let tcm = current.textView.textContentStorage else { return }
        let textView = current.textView
        let scrollView = current.scrollView
        let end = tlm.documentRange.endLocation
        if let start = tcm.location(end, offsetBy: -3000), let tail = NSTextRange(location: start, end: end) {
            tlm.ensureLayout(for: tail)
        } else {
            tlm.ensureLayout(for: tlm.documentRange)
        }
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()
        let height = textView.frame.height + scrollView.contentInsets.bottom
        let clip = scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: 0, y: max(0, height - clip.bounds.height)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Document y of the first line of the latest question.
    private func questionTop(_ doc: Document) -> CGFloat? {
        guard let id = Self.lastQuestion(doc.rows), let index = doc.rows.firstIndex(where: { $0.id == id }),
              let tlm = doc.textView.textLayoutManager, let tcm = doc.textView.textContentStorage else { return nil }
        let offset = doc.rendered.prefix(index).reduce(0) { $0 + $1.length }
        guard let location = tcm.location(tcm.documentRange.location, offsetBy: offset),
              let fromQuestion = NSTextRange(location: location, end: tcm.documentRange.endLocation) else { return nil }
        tlm.ensureLayout(for: fromQuestion)
        guard let fragment = tlm.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame.minY + doc.textView.textContainerInset.height
    }

    /// Estimated above the laid-out part, exact below it (`questionTop` laid out the tail).
    private func documentHeight(_ doc: Document) -> CGFloat {
        guard let tlm = doc.textView.textLayoutManager else { return 0 }
        return tlm.usageBoundsForTextContainer.height + doc.textView.textContainerInset.height * 2
    }

    /// Room below the latest exchange so the question can sit at the top while it's answered.
    private func updateBottomInset(_ doc: Document) {
        let scrollView = doc.scrollView
        guard doc.pinnedQuestion != nil, let top = questionTop(doc) else {
            if scrollView.contentInsets.bottom != 0 { scrollView.contentInsets.bottom = 0 }
            return
        }
        let exchange = documentHeight(doc) - top
        let extra = max(0, scrollView.contentView.bounds.height - (style.compact ? 24 : 48) - exchange)
        if abs(scrollView.contentInsets.bottom - extra) > 0.5 {
            scrollView.contentInsets.bottom = extra
        }
    }

    private func scrollQuestionToTop(animated: Bool) {
        guard let doc = current, let top = questionTop(doc) else { return }
        let scrollView = doc.scrollView
        let target = NSPoint(x: 0, y: max(0, top - doc.textView.textContainerInset.height))
        let clip = scrollView.contentView
        if animated, !Self.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.45
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Helpers

    private static func lastQuestion(_ rows: [TranscriptRow]) -> Int? {
        rows.last(where: { if case .user = $0.kind { true } else { false } })?.id
    }

    /// The text still arriving, if the last row is being answered and ends in text.
    private static func liveText(in rows: [TranscriptRow]) -> String? {
        guard case let .assistant(messages, _, live)? = rows.last?.kind, live,
              case let .text(t)? = messages.last?.content.last else { return nil }
        return t
    }

    // MARK: NSTextLayoutManagerDelegate

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                       textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, DecoratedFragment.wants(paragraph.attributedString) {
            return DecoratedFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

// MARK: - Rows

struct RowRender {
    var signature: Int
    let string: NSAttributedString
    let attachments: [String: ViewAttachment]
    /// Link hosts whose icon wasn't loaded yet; the row is rebuilt when they arrive.
    let missingHosts: Set<String>
    var length: Int { string.length }

    static func signature(_ row: TranscriptRow, isLast: Bool, running: Bool,
                          runningTools: Set<String>, liveOverride: String?) -> Int {
        var h = Hasher()
        h.combine(row.id)
        switch row.kind {
        case let .user(u):
            h.combine(0)
            h.combine(u)
        case let .assistant(messages, results, live):
            h.combine(1)
            h.combine(messages)
            h.combine(results)
            h.combine(live)
            if live {
                h.combine(runningTools)
                h.combine(liveOverride)
            }
            h.combine(isLast)
            h.combine(running)
        }
        return h.finalize()
    }
}

extension NSAttributedString.Key {
    /// Paragraph is a quote: a bar is drawn down its left edge.
    static let transcriptQuote = NSAttributedString.Key("aist.transcriptQuote")
    /// Inline code: a rounded tint is drawn behind the run.
    static let transcriptCode = NSAttributedString.Key("aist.transcriptCode")
}

struct TranscriptStyle {
    let compact: Bool
    var body: NSFont { .systemFont(ofSize: compact ? 12 : 13) }
    var mono: NSFont { .monospacedSystemFont(ofSize: compact ? 11 : 12, weight: .regular) }
    func heading(_ level: Int) -> NSFont {
        .systemFont(ofSize: level <= 2 ? (compact ? 13 : 15) : (compact ? 12 : 13), weight: .semibold)
    }
    var lineSpacing: CGFloat { compact ? 1 : 3 }
    var blockGap: CGFloat { compact ? 6 : 10 }
    var itemGap: CGFloat { compact ? 3 : 5 }
    var rowGap: CGFloat { compact ? 12 : 22 }
    var indent: CGFloat { 18 }
}

/// Builds one row's attributed string. Attachments are reused by key across rebuilds of the same
/// row, so a step row keeps its expanded state and its shimmer while the answer streams.
@MainActor
struct RowBuilder {
    let style: TranscriptStyle
    let session: AgentSession
    let onResize: (ViewAttachment) -> Void

    init(style: TranscriptStyle, session: AgentSession, onResize: @escaping (ViewAttachment) -> Void) {
        self.style = style
        self.session = session
        self.onResize = onResize
    }

    private final class Output {
        let string = NSMutableAttributedString()
        var attachments: [String: ViewAttachment] = [:]
        var missing = Set<String>()
    }

    func build(_ row: TranscriptRow, isLast: Bool, liveOverride: String?,
               reuse: [String: ViewAttachment], signature: Int) -> RowRender {
        let out = Output()
        switch row.kind {
        case let .user(u):
            attach(out, key: "user", content: u, reuse: reuse, gap: style.rowGap) {
                UserBubble(message: u, compact: style.compact)
            }
        case let .assistant(messages, results, live):
            assistant(out, messages: messages, results: results, live: live, isLast: isLast,
                      liveOverride: liveOverride, reuse: reuse)
        }
        // The row ends with the row gap, whatever its last paragraph was.
        setLastParagraphSpacing(out.string, style.rowGap)
        return RowRender(signature: signature, string: out.string, attachments: out.attachments, missingHosts: out.missing)
    }

    private func assistant(_ out: Output, messages: [AssistantMessage], results: [String: ToolResultMessage],
                           live: Bool, isLast: Bool, liveOverride: String?, reuse: [String: ViewAttachment]) {
        let parts = AssistantTurn.parts(messages: messages, results: results, live: live, runningTools: session.runningTools)
        let compact = style.compact
        for (pi, item) in AssistantTurn.displayed(parts, live: live).enumerated() {
            switch item {
            case let .part(.text(t, isLive)):
                let text = isLive ? (liveOverride ?? t) : t
                let blocks = isLive ? MarkdownBlocks.parse(text) : MarkdownCache.blocks(text)
                for (bi, block) in blocks.enumerated() {
                    self.block(out, block, key: "\(pi).\(bi)", reuse: reuse, cache: !isLive || bi < blocks.count - 1)
                }
            case let .part(.thinking(t, isLive)):
                attach(out, key: "think:\(pi)", content: [t, isLive ? "1" : "0"], reuse: reuse, gap: style.blockGap) {
                    ThinkingRow(text: t, live: isLive, compact: compact)
                }
            case let .part(.step(s)):
                attach(out, key: "step:\(pi)", content: [s.title, s.running ? "1" : "0", s.error ?? "", "\(s.sources.count)"],
                       reuse: reuse, gap: style.blockGap) {
                    StepRow(step: s, compact: compact)
                }
            case let .activity(steps):
                let content = steps.map { part -> String in
                    switch part {
                    case let .step(s): return s.title
                    case .thinking: return "thinking"
                    case .text: return ""
                    }
                }
                attach(out, key: "activity", content: content, reuse: reuse, gap: style.blockGap) {
                    ActivitySummary(parts: steps, compact: compact) { part in
                        switch part {
                        case let .thinking(t, isLive): ThinkingRow(text: t, live: isLive, compact: compact)
                        case let .step(s): StepRow(step: s, compact: compact)
                        case .text: EmptyView()
                        }
                    }
                }
            }
        }
        if live, !AssistantTurn.hasVisibleProgress(parts) {
            attach(out, key: "shimmer", content: "shimmer", reuse: reuse, gap: style.blockGap) {
                ShimmerText("思考中…", font: compact ? .caption : .callout)
            }
        }
        if let failed = messages.last, !live {
            switch failed.stopReason {
            case .error:
                note(out, "⚠︎ " + (failed.errorMessage ?? "出错了"), color: .secondaryLabelColor)
            case .aborted:
                note(out, "已停止", color: .tertiaryLabelColor, small: true)
            case .length:
                note(out, "回答达到长度上限，被截断了", color: .tertiaryLabelColor, small: true)
            default: break
            }
        }
        if !live {
            let sources = AssistantTurn.sources(messages: messages, results: results)
            let answer = AssistantTurn.answerText(messages)
            let onRetry: (() -> Void)? = session.isRunning ? nil : { [weak session] in session?.retry() }
            if !sources.isEmpty || !answer.isEmpty || onRetry != nil {
                let model = messages.last.flatMap { $0.usage.output > 0 && !compact ? $0.model : nil }
                let content: [AnyHashable] = [sources, answer.count, isLast, onRetry != nil, model ?? ""]
                attach(out, key: "footer", content: content, reuse: reuse, gap: style.blockGap) {
                    AssistantFooter(sources: sources, answerText: answer, isLast: isLast,
                                    model: model, compact: compact, onRetry: onRetry)
                }
            }
        }
    }

    // MARK: Blocks

    private func block(_ out: Output, _ block: MarkdownBlocks.Block, key: String,
                       reuse: [String: ViewAttachment], cache: Bool) {
        switch block {
        case let .heading(level, s):
            let p = paragraphStyle(spacing: style.blockGap)
            p.paragraphSpacingBefore = style.compact ? 2 : 4
            out.string.append(inline(s, font: style.heading(level), color: .labelColor, paragraph: p, out: out, cache: cache))
            out.string.append(newline(p))
        case let .paragraph(s):
            let p = paragraphStyle(spacing: style.blockGap)
            out.string.append(inline(s, font: style.body, color: .labelColor, paragraph: p, out: out, cache: cache))
            out.string.append(newline(p))
        case let .list(items):
            for (i, item) in items.enumerated() {
                let lead = CGFloat(item.level) * style.indent
                let p = paragraphStyle(spacing: i == items.count - 1 ? style.blockGap : style.itemGap)
                p.firstLineHeadIndent = lead
                p.headIndent = lead + style.indent
                p.tabStops = [NSTextTab(textAlignment: .left, location: lead + style.indent)]
                p.defaultTabInterval = style.indent
                out.string.append(NSAttributedString(string: item.marker + "\t", attributes: [
                    .font: style.body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p,
                ]))
                out.string.append(inline(item.text, font: style.body, color: .labelColor, paragraph: p, out: out, cache: cache))
                out.string.append(newline(p))
            }
        case let .quote(s):
            let p = paragraphStyle(spacing: style.blockGap)
            p.firstLineHeadIndent = 13
            p.headIndent = 13
            let q = NSMutableAttributedString(attributedString: inline(s, font: style.body, color: .secondaryLabelColor, paragraph: p, out: out, cache: cache))
            q.addAttribute(.transcriptQuote, value: true, range: NSRange(location: 0, length: q.length))
            out.string.append(q)
            out.string.append(newline(p, extra: [.transcriptQuote: true]))
        case let .code(lang, code):
            let compact = style.compact
            attach(out, key: "code:\(key)", content: [lang, code], reuse: reuse, gap: style.blockGap) {
                CodeBlock(language: lang, code: code, compact: compact)
            }
        case let .table(header, rows):
            attachNative(out, key: "table:\(key)", content: [header] + rows, reuse: reuse, gap: style.blockGap) {
                TableBody(header: header, rows: rows, style: style)
            }
        case .rule:
            attach(out, key: "rule:\(key)", content: "rule", reuse: reuse, gap: style.blockGap) {
                Divider().padding(.vertical, 4)
            }
        }
    }

    private func note(_ out: Output, _ text: String, color: NSColor, small: Bool = false) {
        let p = paragraphStyle(spacing: style.blockGap)
        out.string.append(NSAttributedString(string: text, attributes: [
            .font: small ? NSFont.systemFont(ofSize: 10) : style.body, .foregroundColor: color, .paragraphStyle: p,
        ]))
        out.string.append(newline(p))
    }

    private func paragraphStyle(spacing: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = style.lineSpacing
        p.paragraphSpacing = spacing
        p.lineBreakMode = .byWordWrapping
        return p
    }

    private func newline(_ p: NSParagraphStyle, extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: style.body, .paragraphStyle: p]
        attrs.merge(extra) { $1 }
        return NSAttributedString(string: "\n", attributes: attrs)
    }

    private func setLastParagraphSpacing(_ s: NSMutableAttributedString, _ spacing: CGFloat) {
        guard s.length > 0 else { return }
        let ns = s.string as NSString
        let start = ns.paragraphRange(for: NSRange(location: s.length - 1, length: 0)).location
        let range = NSRange(location: start, length: s.length - start)
        let p = (s.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle(spacing: spacing)
        p.paragraphSpacing = spacing
        s.addAttribute(.paragraphStyle, value: p, range: range)
    }

    // MARK: Inline

    private func inline(_ s: String, font: NSFont, color: NSColor, paragraph: NSParagraphStyle,
                        out: Output, cache: Bool) -> NSAttributedString {
        let attr = cache ? MarkdownCache.inline(s) : (MarkdownCache.cached(s) ?? MarkdownText.inline(s))
        return InlineText.attributed(attr, font: font, color: color, mono: style.mono, paragraph: paragraph,
                                     icons: true, missing: &out.missing)
    }

    // MARK: Attachments

    private func attach<V: View>(_ out: Output, key: String, content: AnyHashable, reuse: [String: ViewAttachment],
                                 gap: CGFloat, @ViewBuilder _ view: () -> V) {
        let attachment = reuse[key] ?? ViewAttachment(key: key)
        if attachment.onResize == nil { attachment.onResize = onResize }
        attachment.setHosted(content: content) { ViewAttachment.wrap(view(), attachment) }
        place(out, attachment, key: key, gap: gap)
    }

    private func attachNative(_ out: Output, key: String, content: AnyHashable, reuse: [String: ViewAttachment],
                              gap: CGFloat, _ make: () -> AttachmentBody) {
        let attachment = reuse[key] ?? ViewAttachment(key: key)
        attachment.setNative(content: content, make)
        place(out, attachment, key: key, gap: gap)
    }

    private func place(_ out: Output, _ attachment: ViewAttachment, key: String, gap: CGFloat) {
        out.attachments[key] = attachment
        let p = paragraphStyle(spacing: gap)
        p.lineSpacing = 0
        out.string.append(NSAttributedString(attachment: attachment))
        out.string.addAttribute(.paragraphStyle, value: p, range: NSRange(location: out.string.length - 1, length: 1))
        out.string.append(newline(p))
    }
}

/// Inline markdown (Foundation's parse) → AppKit attributes, each web link led by its site icon.
@MainActor
enum InlineText {
    static func attributed(_ attr: AttributedString, font: NSFont, color: NSColor, mono: NSFont,
                           paragraph: NSParagraphStyle?, icons: Bool, missing: inout Set<String>) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previousLink: URL?
        let manager = NSFontManager.shared
        for run in attr.runs {
            let piece = String(attr[run.range].characters)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let paragraph { attrs[.paragraphStyle] = paragraph }
            var f = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { f = manager.convert(f, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { f = manager.convert(f, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) {
                f = mono
                attrs[.transcriptCode] = true
            }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attrs[.font] = f
            if let link = run.link {
                attrs[.link] = link
                if icons, link != previousLink, let host = link.host, link.scheme?.hasPrefix("http") == true {
                    let key = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                    if let icon = FaviconStore.shared.image(for: key) {
                        let a = NSTextAttachment()
                        a.image = icon
                        a.bounds = CGRect(x: 0, y: -2.5, width: 14, height: 14)
                        result.append(NSAttributedString(attachment: a))
                        var gapAttrs: [NSAttributedString.Key: Any] = [.font: f]
                        if let paragraph { gapAttrs[.paragraphStyle] = paragraph }
                        result.append(NSAttributedString(string: "\u{2009}", attributes: gapAttrs))
                    } else {
                        missing.insert(key)
                    }
                }
            }
            result.append(NSAttributedString(string: piece, attributes: attrs))
            previousLink = run.link
        }
        return result
    }
}

// MARK: - Embedded views

/// Something a `ViewAttachment` shows: an AppKit view that knows its height for a width.
@MainActor
protocol AttachmentBody: AnyObject {
    var view: NSView { get }
    func height(for width: CGFloat) -> CGFloat
}

/// A SwiftUI view, measured by its hosting controller.
@MainActor
final class HostedBody: AttachmentBody {
    let controller: NSHostingController<AnyView>
    var view: NSView { controller.view }

    init(_ view: AnyView) {
        controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
    }

    func height(for width: CGFloat) -> CGFloat {
        controller.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
    }
}

/// A full-width block in the text, as tall as its content. The same attachment object lives on
/// across rebuilds of its row (SwiftUI state such as "expanded" survives) and across conversations
/// shown in the same row slot; measured heights are kept per content, so a revisit costs nothing.
final class ViewAttachment: NSTextAttachment {
    let key: String
    private(set) var body: (any AttachmentBody)?
    private var content: AnyHashable?
    private var measured: [CGFloat: CGFloat] = [:]
    var onResize: ((ViewAttachment) -> Void)?

    init(key: String) {
        self.key = key
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        // Without an image TextKit draws a document icon under the view.
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `view`; a hosted body is kept and only its root view replaced.
    // TextKit and the row builder only ever touch attachments on the main thread; the class can't be
    // marked @MainActor because NSTextAttachment's overrides are nonisolated.
    func setHosted(content: AnyHashable, _ view: () -> AnyView) {
        MainActor.assumeIsolated {
            if let hosted = body as? HostedBody {
                guard self.content != content else { return }
                hosted.controller.rootView = view()
            } else {
                body = HostedBody(view())
            }
            self.content = content
            measured = [:]
        }
    }

    func setNative(content: AnyHashable, _ make: () -> AttachmentBody) {
        MainActor.assumeIsolated {
            guard self.content != content || !(body is NativeMarker) else { return }
            body = make()
            self.content = content
            measured = [:]
        }
    }

    var bodyView: NSView? { MainActor.assumeIsolated { body?.view } }

    static func wrap<V: View>(_ view: V, _ attachment: ViewAttachment) -> AnyView {
        AnyView(
            view
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak attachment] height in
                    attachment?.noteHeight(height)
                }
        )
    }

    func height(for width: CGFloat) -> CGFloat {
        let w = width.rounded()
        if let h = measured[w] { return h }
        let h = MainActor.assumeIsolated { (body?.height(for: w) ?? 0).rounded(.up) }
        measured[w] = h
        return h
    }

    /// The content's natural height changed (it expanded or collapsed).
    private func noteHeight(_ height: CGFloat) {
        guard let view = bodyView else { return }
        let w = view.frame.width.rounded()
        guard let known = measured[w], abs(known - height.rounded(.up)) > 0.5 else { return }
        measured = [:]
        onResize?(self)
    }

    override func viewProvider(for parentView: NSView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        HostingProvider(attachment: self, parentView: parentView, location: location, textContainer: textContainer)
    }
}

/// Marks native (non-SwiftUI) bodies so a content change rebuilds them.
protocol NativeMarker {}

final class HostingProvider: NSTextAttachmentViewProvider {
    let attachment: ViewAttachment

    init(attachment: ViewAttachment, parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) {
        self.attachment = attachment
        super.init(textAttachment: attachment, parentView: parentView,
                   textLayoutManager: textContainer?.textLayoutManager, location: location)
        tracksTextAttachmentViewBounds = true
    }

    override func loadView() {
        guard let v = attachment.bodyView else { view = NSView(); return }
        v.removeFromSuperview()
        let width = textLayoutManager?.textContainer?.size.width ?? v.frame.width
        if width > 0 { v.frame.size = CGSize(width: width, height: attachment.height(for: width)) }
        view = v
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        let width = proposedLineFragment.width
        return CGRect(x: 0, y: 0, width: width, height: attachment.height(for: width))
    }
}

/// Paragraphs with decorations drawn behind the text: a rounded tint under inline code, a soft bar
/// down the left of a quote.
final class DecoratedFragment: NSTextLayoutFragment {
    static func wants(_ s: NSAttributedString) -> Bool {
        guard s.length > 0 else { return false }
        if s.attribute(.transcriptQuote, at: 0, effectiveRange: nil) != nil { return true }
        var found = false
        s.enumerateAttribute(.transcriptCode, in: NSRange(location: 0, length: s.length), options: []) { v, _, stop in
            if v != nil { found = true; stop.pointee = true }
        }
        return found
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        if let paragraph = (textElement as? NSTextParagraph)?.attributedString {
            drawCodeTints(paragraph, at: point, in: context)
            if paragraph.attribute(.transcriptQuote, at: 0, effectiveRange: nil) != nil {
                let height = textLineFragments.last.map { $0.typographicBounds.maxY } ?? layoutFragmentFrame.height
                context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
                let bar = CGRect(x: point.x, y: point.y, width: 3, height: max(0, height))
                context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                context.fillPath()
            }
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    private func drawCodeTints(_ paragraph: NSAttributedString, at point: CGPoint, in context: CGContext) {
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.075).cgColor)
        for line in textLineFragments {
            let lineRange = line.characterRange
            guard lineRange.length > 0 else { continue }
            paragraph.enumerateAttribute(.transcriptCode, in: lineRange, options: []) { value, range, _ in
                guard value != nil else { return }
                let x0 = line.locationForCharacter(at: range.location).x
                let x1 = line.locationForCharacter(at: range.location + range.length).x
                guard x1 > x0 else { return }
                let bounds = line.typographicBounds
                let rect = CGRect(x: point.x + bounds.minX + x0 - 2, y: point.y + bounds.minY + 1.5,
                                  width: x1 - x0 + 4, height: bounds.height - 3)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.fillPath()
            }
        }
    }
}

// MARK: - Native table

/// A Markdown table drawn directly: cells measured once per width with CoreText, header in
/// semibold, a hairline under it, rows wrapping in place.
@MainActor
final class TableBody: NSView, AttachmentBody, NativeMarker {
    private let cells: [[NSAttributedString]]   // header first
    private let columns: Int
    private let hSpacing: CGFloat = 14
    private let vSpacing: CGFloat = 6
    private let padding: CGFloat = 4
    private var layoutCache: (width: CGFloat, columnWidths: [CGFloat], rowHeights: [CGFloat])?

    var view: NSView { self }
    override var isFlipped: Bool { true }

    init(header: [String], rows: [[String]], style: TranscriptStyle) {
        columns = max(1, header.count)
        var unused = Set<String>()
        let semibold = NSFont.systemFont(ofSize: style.body.pointSize, weight: .semibold)
        func cell(_ s: String, bold: Bool) -> NSAttributedString {
            InlineText.attributed(MarkdownCache.inline(s), font: bold ? semibold : style.body, color: .labelColor,
                                  mono: style.mono, paragraph: nil, icons: true, missing: &unused)
        }
        var all: [[NSAttributedString]] = [header.map { cell($0, bold: true) }]
        for row in rows {
            all.append((0..<columns).map { i in cell(i < row.count ? row[i] : "", bold: false) })
        }
        cells = all
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func measure(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        guard s.length > 0 else { return CGSize(width: 0, height: 16) }
        let r = s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Column widths: what each column wants on one line, shrunk proportionally to fit.
    private func layoutTable(width: CGFloat) -> (columnWidths: [CGFloat], rowHeights: [CGFloat]) {
        if let c = layoutCache, c.width == width { return (c.columnWidths, c.rowHeights) }
        var ideal = [CGFloat](repeating: 0, count: columns)
        for row in cells {
            for (i, cell) in row.enumerated() where i < columns {
                ideal[i] = max(ideal[i], measure(cell, width: 4000).width)
            }
        }
        let available = max(0, width - hSpacing * CGFloat(columns - 1))
        let total = ideal.reduce(0, +)
        var widths = ideal
        if total > available, total > 0 {
            let minimum = min(60, available / CGFloat(columns))
            // Narrow columns keep their width; wide ones share what's left.
            let fixed = ideal.filter { $0 <= minimum }.reduce(0, +)
            let flexible = total - fixed
            let room = max(0, available - fixed)
            widths = ideal.map { $0 <= minimum ? $0 : max(minimum, $0 / flexible * room) }
        }
        let heights = cells.map { row -> CGFloat in
            var h: CGFloat = 0
            for (i, cell) in row.enumerated() where i < columns {
                h = max(h, measure(cell, width: widths[i]).height)
            }
            return h
        }
        layoutCache = (width, widths, heights)
        return (widths, heights)
    }

    func height(for width: CGFloat) -> CGFloat {
        let (_, heights) = layoutTable(width: width)
        return padding * 2 + heights.reduce(0, +) + vSpacing * CGFloat(max(0, heights.count - 1)) + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        let (widths, heights) = layoutTable(width: bounds.width)
        var y = padding
        for (r, row) in cells.enumerated() {
            var x: CGFloat = 0
            for (i, cell) in row.enumerated() where i < columns {
                cell.draw(with: CGRect(x: x, y: y, width: widths[i], height: heights[r]),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
                x += widths[i] + hSpacing
            }
            y += heights[r]
            if r == 0 {
                y += vSpacing / 2
                NSColor.separatorColor.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
                y += vSpacing / 2 + 1
            } else {
                y += vSpacing
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
#endif
