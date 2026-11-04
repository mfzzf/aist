import AistAI
import AistAgent
import Foundation
import SwiftUI

/// Something the host puts in front of the model, e.g. the mail that's open. Shown as a chip.
public struct ContextItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String
    /// What the model reads.
    public var text: String

    public init(id: String, title: String, systemImage: String, text: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.text = text
    }
}

/// A model the user can pick in the composer.
public struct ModelOption: Identifiable, Hashable, Sendable {
    /// "provider/model".
    public var id: String { "\(provider)/\(model)" }
    public var provider: String
    public var providerName: String
    public var model: String

    public init(provider: String, providerName: String, model: String) {
        self.provider = provider
        self.providerName = providerName
        self.model = model
    }
}

/// One conversation as the UI sees it: the transcript, the message streaming in, and the controls.
/// Hosts create one per chat (the Q&A pane, a pop-up over a mail…) and hand it to `AgentChatView`.
@MainActor
public final class AgentSession: ObservableObject, Identifiable {
    public nonisolated let id = UUID()

    @Published public private(set) var messages: [Message] = []
    /// The assistant message being streamed (batched to ~30 fps; text reveal is smoothed per frame).
    @Published public private(set) var streaming: AssistantMessage?
    @Published public private(set) var runningTools: Set<String> = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var conversationID: UUID?
    @Published public private(set) var title: String?
    /// Setup problems (no key, …) — not model errors, which live in the transcript.
    @Published public var problem: String?
    @Published public var draft = ""
    /// Bumped when another conversation is shown (no animation then); views key their scroll state on it.
    @Published public private(set) var openSerial = 0
    /// The composer's model picker is open.
    @Published public var pickingModel = false
    @Published public var context: [ContextItem]
    /// Models offered in the composer; the host keeps this current.
    @Published public var models: [ModelOption] = []
    /// The picked model; nil = the host's default.
    @Published public var selectedModel: ModelOption? {
        didSet { if let m = selectedModel, m != oldValue, !restoringModel { onSelectModel?(m) } }
    }
    /// Remember the choice for new conversations.
    public var onSelectModel: (@MainActor (ModelOption) -> Void)?

    /// Built fresh on every send (for the picked model) so Settings changes apply at once.
    public typealias Configure = @MainActor (ModelOption?) throws -> AgentConfig
    private let configure: Configure
    private let store: ConversationStore?
    public let scope: String
    /// Called after the conversation is created, renamed or gets new messages.
    public var onChange: (@MainActor (UUID) -> Void)?

    private var task: Task<Void, Never>?
    private var pending: AssistantMessage?
    private var flushScheduled = false

    public init(store: ConversationStore?, scope: String = "chat", context: [ContextItem] = [], configure: @escaping Configure) {
        self.store = store
        self.scope = scope
        self.context = context
        self.configure = configure
    }

    // MARK: - Conversations

    /// Shows a saved conversation. Recently seen ones come from memory, others load first; either
    /// way the swap happens on the next run-loop turn, never inside the SwiftUI update that
    /// delivered the click. (Swapping synchronously from an `onChange` made SwiftUI re-enter its
    /// own layout for every published property and lock up.) A newer click wins over a slower load.
    public func open(_ id: UUID?) {
        NavTrace.log("session.open \(id?.uuidString.prefix(8) ?? "nil") current=\(conversationID?.uuidString.prefix(8) ?? "nil") cached=\(id.map { recent[$0] != nil } ?? false)")
        guard id != conversationID || id == nil else { return }
        guard let id, let store else { reset(); return }
        openGeneration += 1
        let generation = openGeneration
        if let cached = recent[id] {
            Task { @MainActor [weak self] in
                guard let self, generation == self.openGeneration else { return }
                self.show(cached, id: id)
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var loaded: [Message] = []
            do { loaded = try await store.messages(of: id) } catch { problem = error.localizedDescription }
            guard generation == openGeneration else { return }
            remember(loaded, for: id)
            show(loaded, id: id)
        }
    }

    /// Loads conversations into memory ahead of a click (e.g. the ones listed in the sidebar).
    public func prefetch(_ ids: [UUID]) {
        guard let store else { return }
        let missing = ids.filter { recent[$0] == nil }.prefix(Self.recentLimit)
        guard !missing.isEmpty else { return }
        Task {
            for id in missing {
                guard recent[id] == nil, let loaded = try? await store.messages(of: id) else { continue }
                remember(loaded, for: id)
            }
        }
    }

    private func show(_ loaded: [Message], id: UUID) {
        NavTrace.log("session.show \(id.uuidString.prefix(8)) messages=\(loaded.count)")
        stop()
        // Continue with the model that answered last, if it's still offered.
        var model = selectedModel
        if let last = loaded.last(where: { if case .assistant = $0 { true } else { false } }),
           case let .assistant(a) = last,
           let option = models.first(where: { $0.provider == a.provider && $0.model == a.model }) {
            model = option
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            messages = loaded
            streaming = nil
            runningTools = []
            problem = nil
            conversationID = id
            title = nil
            restoringModel = true
            selectedModel = model
            restoringModel = false
            openSerial += 1
        }
    }

    /// Set while `show` restores a conversation's model: not a user choice, so not remembered.
    private var restoringModel = false

    private static let recentLimit = 30
    private var recent: [UUID: [Message]] = [:]
    private var recentOrder: [UUID] = []
    private var openGeneration = 0

    private func remember(_ messages: [Message], for id: UUID) {
        recent[id] = messages
        recentOrder.removeAll { $0 == id }
        recentOrder.append(id)
        if recentOrder.count > Self.recentLimit { recent[recentOrder.removeFirst()] = nil }
    }

    public func reset() {
        stop()
        openGeneration += 1
        openSerial += 1
        messages = []
        streaming = nil
        conversationID = nil
        title = nil
        problem = nil
    }

    // MARK: - Sending

    public var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning }

    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        draft = ""
        run(prompt: [.user(UserMessage(text))], history: messages)
    }

    /// Runs the last question again, dropping the failed/stopped answer.
    public func retry() {
        guard !isRunning, let last = messages.lastIndex(where: { if case .user = $0 { true } else { false } }) else { return }
        let prompt = messages[last]
        let history = Array(messages[..<last])
        let dropFrom = last
        messages = history
        if let id = conversationID, let store {
            recent[id] = nil
            Task { try? await store.truncate(id, keeping: dropFrom) }
        }
        run(prompt: [prompt], history: history)
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func run(prompt: [Message], history: [Message]) {
        problem = nil
        var config: AgentConfig
        do { config = try configure(selectedModel) } catch {
            problem = error.localizedDescription
            return
        }
        if !context.isEmpty {
            let blocks = context.map { "<context title=\"\($0.title)\">\n\($0.text)\n</context>" }.joined(separator: "\n")
            config.systemPrompt = (config.systemPrompt ?? "") + "\n\n用户正在看下面的内容，问题多半与它有关：\n" + blocks
        }
        isRunning = true
        streaming = nil
        let titleModel = (config.model, config.options.apiKey)
        task = Task { [weak self] in
            var added: [Message] = []
            for await event in AgentLoop.run(prompt: prompt, history: history, config: config) {
                guard let self else { return }
                switch event {
                case let .message(m):
                    if case .assistant = m { self.pending = nil; self.streaming = nil }
                    if case let .toolResult(r) = m { self.runningTools.remove(r.toolCallId) }
                    if case .user = m {
                        // The one animated change: the question slides in (and the composer down).
                        withAnimation(.smooth(duration: 0.45)) { self.messages.append(m) }
                    } else {
                        self.messages.append(m)
                    }
                case let .messageUpdate(e):
                    self.pending = e.partial
                    self.scheduleFlush()
                case let .toolExecutionStart(id, _, _):
                    self.runningTools.insert(id)
                case let .agentEnd(newMessages):
                    added = newMessages
                default: break
                }
            }
            guard let self else { return }
            self.pending = nil
            self.streaming = nil
            self.runningTools = []
            self.isRunning = false
            self.task = nil
            await self.persist(added, titleWith: titleModel)
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard let self else { return }
            self.flushScheduled = false
            if let p = self.pending { self.streaming = p }
        }
    }

    // MARK: - Storage

    private func persist(_ added: [Message], titleWith model: (Model, String?)) async {
        guard let store, !added.isEmpty else { return }
        do {
            var isNew = false
            if conversationID == nil {
                let first = added.compactMap { if case let .user(u) = $0 { Self.plain(u) } else { nil } }.first ?? "新对话"
                let summary = try await store.create(title: String(first.prefix(30)), scope: scope)
                conversationID = summary.id
                title = summary.title
                isNew = true
            }
            guard let id = conversationID else { return }
            try await store.append(added, to: id)
            if conversationID == id { remember(messages, for: id) }
            onChange?(id)
            if isNew { await makeTitle(id, model: model) }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// A short title from the first exchange, in the background.
    private func makeTitle(_ id: UUID, model: (Model, String?)) async {
        guard let store else { return }
        let question = messages.compactMap { if case let .user(u) = $0 { Self.plain(u) } else { nil } }.first ?? ""
        let answer = messages.compactMap { if case let .assistant(a) = $0 { a.text } else { nil } }.joined().prefix(400)
        let ctx = Context(
            systemPrompt: "给这段对话起一个不超过 12 个字的标题，只输出标题本身，不要引号和标点结尾。用对话的语言。",
            messages: [.user(UserMessage("问：\(question.prefix(300))\n答：\(answer)"))]
        )
        let reply = await AI.complete(model.0, ctx, StreamOptions(apiKey: model.1, maxTokens: 40))
        let t = reply.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”《》#*")))
        guard reply.stopReason == .stop, !t.isEmpty, t.count <= 30 else { return }
        try? await store.rename(id, to: t)
        if conversationID == id { title = t }
        onChange?(id)
    }

    static func plain(_ u: UserMessage) -> String {
        u.content.compactMap { if case let .text(t) = $0 { t } else { nil } }.joined(separator: "\n")
    }
}
