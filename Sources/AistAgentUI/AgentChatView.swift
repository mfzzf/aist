import AistAI
import AistAgent
import SwiftUI

/// The chat surface. `.full` for a window pane, `.compact` for a pop-up over something else
/// (a mail, a to-do) — same components and behaviour, tighter spacing and type.
///
/// An empty chat shows a greeting with the composer in the middle; the first question slides the
/// composer down. Each new question scrolls up to the top of the view and the answer grows below it
/// (the last exchange is at least a screen tall), instead of everything piling up at the bottom.
public struct AgentChatView: View {
    public enum Style { case full, compact }

    @ObservedObject var session: AgentSession
    var style: Style
    var suggestions: [String]
    @Namespace private var space

    public init(session: AgentSession, style: Style = .full, suggestions: [String] = []) {
        self.session = session
        self.style = style
        self.suggestions = suggestions
    }

    private var compact: Bool { style == .compact }
    private var columnWidth: CGFloat? { compact ? nil : 760 }

    public var body: some View {
        let rows = TranscriptRow.build(session.messages, streaming: session.streaming, running: session.isRunning)
        ZStack {
            if rows.isEmpty {
                empty
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    Transcript(rows: rows, session: session, compact: compact, width: columnWidth)
                        // A different conversation gets a fresh scroll view, already at its end.
                        .id(session.openSerial)
                    composer
                        .padding(.bottom, compact ? 10 : 18)
                }
                .transition(.opacity)
            }
        }
    }

    private var composer: some View {
        AgentComposer(session: session, compact: compact)
            .matchedGeometryEffect(id: "composer", in: space)
            .zIndex(1)
            .frame(maxWidth: columnWidth.map { $0 + 32 } ?? .infinity)
            .padding(.horizontal, compact ? 10 : 24)
            .frame(maxWidth: .infinity)
    }

    private var empty: some View {
        VStack(spacing: compact ? 12 : 22) {
            Spacer()
            Text(greeting)
                .font(compact ? .headline : .system(size: 26, weight: .regular))
                .multilineTextAlignment(.center)
            composer
            if !suggestions.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button {
                            session.draft = s
                            session.send()
                        } label: {
                            Text(s)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.quaternary.opacity(0.5), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .font(compact ? .caption : .callout)
                .frame(maxWidth: columnWidth ?? .infinity)
                .padding(.horizontal, compact ? 10 : 24)
            }
            Spacer()
            Spacer()
        }
    }

    private var greeting: String {
        if let first = session.context.first { return "关于「\(first.title)」，想问什么？" }
        return "今天想聊点什么？"
    }
}

/// Messages, with the latest exchange pinned to the top of the view while it's answered.
private struct Transcript: View {
    let rows: [TranscriptRow]
    @ObservedObject var session: AgentSession
    var compact: Bool
    var width: CGFloat?

    var body: some View {
        let split = rows.lastIndex(where: { if case .user = $0.kind { true } else { false } }) ?? 0
        let older = Array(rows[..<split])
        let latest = Array(rows[split...])
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 12 : 22) {
                        ForEach(older) { row($0, last: false) }
                        // The newest question and its answer: at least a viewport tall, so the
                        // question can sit at the top with the answer growing beneath it.
                        VStack(alignment: .leading, spacing: compact ? 12 : 22) {
                            ForEach(latest) { row($0, last: $0.id == rows.last?.id) }
                        }
                        .frame(minHeight: max(0, geo.size.height - (compact ? 24 : 48)), alignment: .top)
                        .id(Self.latestID(latest))
                    }
                    .padding(.horizontal, compact ? 12 : 24)
                    .padding(.top, compact ? 10 : 24)
                    .frame(maxWidth: width.map { $0 + 48 } ?? .infinity)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: Self.latestID(latest)) { _, id in
                    withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    static func latestID(_ latest: [TranscriptRow]) -> String { "latest-\(latest.first?.id ?? -1)" }

    @ViewBuilder private func row(_ row: TranscriptRow, last: Bool) -> some View {
        switch row.kind {
        case let .user(u):
            UserBubble(message: u, compact: compact)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        case let .assistant(messages, results, live):
            AssistantTurn(messages: messages, results: results, live: live,
                          runningTools: session.runningTools, compact: compact, isLast: last,
                          onRetry: session.isRunning ? nil : { session.retry() })
        }
    }
}

/// One pill: the text field, the model picker and a round send/stop button.
public struct AgentComposer: View {
    @ObservedObject var session: AgentSession
    var compact: Bool
    @FocusState private var focused: Bool

    public init(session: AgentSession, compact: Bool = false) {
        self.session = session
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = session.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
            }
            if !session.context.isEmpty {
                HStack(spacing: 6) {
                    ForEach(session.context) { item in
                        HStack(spacing: 4) {
                            Image(systemName: item.systemImage)
                            Text(item.title).lineLimit(1)
                            Button {
                                session.context.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("不带上这项内容")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.7), in: Capsule())
                    }
                }
                .padding(.horizontal, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(compact ? "追问…" : "问点什么", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(compact ? .callout : .system(size: 15))
                    .lineLimit(1...(compact ? 5 : 10))
                    .focused($focused)
                    .onSubmit { session.send() }
                    .padding(.vertical, compact ? 5 : 8)
                    .padding(.leading, compact ? 4 : 8)
                ModelMenu(session: session, compact: compact)
                SendButton(session: session, compact: compact)
            }
            .padding(compact ? 5 : 7)
            .modifier(ComposerBackground(radius: compact ? 18 : 26))
            .overlay {
                if session.pickingModel {
                    // Click anywhere else to close.
                    Color.black.opacity(0.001)
                        .frame(width: 6000, height: 6000)
                        .contentShape(Rectangle())
                        .onTapGesture { closePicker() }
                }
            }
            .overlay(alignment: .topTrailing) {
                if session.pickingModel {
                    ModelPanel(session: session) { closePicker() }
                        .alignmentGuide(.top) { $0[.bottom] + 8 }
                        .padding(.trailing, compact ? 30 : 42)
                        .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
        }
        .onAppear { focused = true }
        .onChange(of: session.conversationID) { focused = true }
    }

    private func closePicker() {
        withAnimation(.snappy(duration: 0.18)) { session.pickingModel = false }
    }
}

private struct SendButton: View {
    @ObservedObject var session: AgentSession
    var compact: Bool

    var body: some View {
        let size: CGFloat = compact ? 26 : 34
        Button {
            if session.isRunning { session.stop() } else { session.send() }
        } label: {
            Image(systemName: session.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: size * (session.isRunning ? 0.36 : 0.45), weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(enabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(session.isRunning ? "停止（⌘.）" : "发送（⏎），⌥⏎ 换行")
        .keyboardShortcut(session.isRunning ? KeyboardShortcut(".", modifiers: .command) : nil)
        .animation(.snappy(duration: 0.2), value: enabled)
    }

    private var enabled: Bool { session.isRunning || session.canSend }
}

/// The model button: plain secondary text that turns into a grey capsule on hover or while open.
struct ModelMenu: View {
    @ObservedObject var session: AgentSession
    var compact: Bool
    @State private var hovering = false

    var body: some View {
        if !session.models.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.18)) { session.pickingModel.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(current?.model ?? "选择模型").lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: compact ? 9 : 10, weight: .medium))
                        .rotationEffect(.degrees(session.pickingModel ? 180 : 0))
                }
                .font(compact ? .caption : .system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.horizontal, compact ? 9 : 13)
                .frame(height: compact ? 26 : 34)
                .background {
                    if hovering || session.pickingModel {
                        Capsule().fill(.quaternary.opacity(0.7))
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .fixedSize()
            .help(current.map { "\($0.providerName) · \($0.model)" } ?? "选择模型")
        }
    }

    private var current: ModelOption? { session.selectedModel ?? session.models.first }
}

/// The model list: a rounded panel, current model checked on the right, rows highlight on hover.
struct ModelPanel: View {
    @ObservedObject var session: AgentSession
    var close: () -> Void

    var body: some View {
        let showProvider = Set(session.models.map(\.provider)).count > 1
        VStack(spacing: 2) {
            ForEach(session.models) { option in
                ModelRow(option: option, selected: option.id == current?.id, showProvider: showProvider) {
                    session.selectedModel = option
                    close()
                }
            }
        }
        .padding(6)
        .frame(minWidth: 230)
        .fixedSize()
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.7)))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        .background {
            Button("关闭", action: close).keyboardShortcut(.cancelAction).opacity(0)
        }
    }

    private var current: ModelOption? { session.selectedModel ?? session.models.first }
}

private struct ModelRow: View {
    let option: ModelOption
    let selected: Bool
    let showProvider: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.model).font(.system(size: 14))
                    if showProvider {
                        Text(option.providerName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .medium))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, showProvider ? 6 : 9)
            .background {
                if selected || hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.8 : 0.55))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ComposerBackground: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.background, in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.8)))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 3)
    }
}
