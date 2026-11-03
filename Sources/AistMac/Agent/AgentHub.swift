import AistAI
import AistAgent
import AistAgentUI
import AistCore
import Combine
import Foundation

/// A model offered in the Q&A composer: a provider from Settings › AI plus a model id.
struct AgentModelRef: Codable, Hashable {
    var provider: String
    var model: String
}

/// Q&A settings (Settings › 问答). The Tavily key lives in the Keychain.
enum AgentSettings {
    static let searchKey = "agent.search"
    static let reasoningKey = "agent.reasoning"
    static let modelsKey = "agent.models"
    static let lastModelKey = "agent.lastModel"
    static let tavilyService = "com.aist.tavily-key"

    static var search: SearchBackend {
        UserDefaults.standard.string(forKey: searchKey).flatMap(SearchBackend.init(rawValue:)) ?? .auto
    }

    static var reasoning: Bool { UserDefaults.standard.bool(forKey: reasoningKey) }

    static var tavilyKey: String? { KeychainStore.read(service: tavilyService) }

    /// The models picked in Settings › 问答, in order. Empty = just Settings › AI's default.
    static var models: [AgentModelRef] {
        get {
            UserDefaults.standard.data(forKey: modelsKey)
                .flatMap { try? JSONDecoder().decode([AgentModelRef].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: modelsKey) }
    }

    /// What the composer offers: the saved list, or the default provider's model when it's empty.
    static func options() -> [ModelOption] {
        let state = LLMProviderStore.load()
        var refs = models
        if refs.isEmpty, let current = state.current, !current.model.isEmpty {
            refs = [AgentModelRef(provider: current.id, model: current.model)]
        }
        return refs.compactMap { ref in
            state.providers.first { $0.id == ref.provider }
                .map { ModelOption(provider: ref.provider, providerName: $0.name, model: ref.model) }
        }
    }
}

/// Owns the agent pieces the app shares: the conversation store, the Q&A pane's list and session,
/// and a factory for compact pop-up sessions (e.g. over a mail) that look and behave the same.
@MainActor
final class AgentHub: ObservableObject {
    let store: ConversationStore?
    let library: AgentLibrary
    let session: AgentSession
    /// Why the store couldn't open, if it couldn't (chats then work but aren't saved).
    let storeProblem: String?
    private var observer: AnyCancellable?

    init() {
        var problem: String?
        do { store = try ConversationStore() } catch {
            store = nil
            problem = error.localizedDescription
        }
        storeProblem = problem
        library = AgentLibrary(store: store, scope: "chat")
        session = AgentSession(store: store, scope: "chat") { try AgentHub.config($0) }
        session.onChange = { [weak library] _ in Task { await library?.reload() } }
        prepare(session)
        observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshModels() }
    }

    /// A separate conversation about something specific — shown with `AgentChatView(style: .compact)`.
    func popupSession(scope: String, context: [ContextItem], extraTools: [AgentTool] = []) -> AgentSession {
        let s = AgentSession(store: store, scope: scope, context: context) {
            var c = try AgentHub.config($0)
            c.tools += extraTools
            return c
        }
        prepare(s)
        return s
    }

    /// Re-reads the model list (Settings changed).
    func refreshModels() {
        let options = AgentSettings.options()
        guard options != session.models else { return }
        session.models = options
        if let picked = session.selectedModel, !options.contains(picked) {
            session.selectedModel = Self.lastPicked(in: options)
        }
    }

    private func prepare(_ s: AgentSession) {
        let options = AgentSettings.options()
        s.models = options
        s.selectedModel = Self.lastPicked(in: options)
        s.onSelectModel = { UserDefaults.standard.set($0.id, forKey: AgentSettings.lastModelKey) }
    }

    private static func lastPicked(in options: [ModelOption]) -> ModelOption? {
        let last = UserDefaults.standard.string(forKey: AgentSettings.lastModelKey)
        return options.first { $0.id == last } ?? options.first
    }

    /// Model, key and tools for `option` (or Settings › AI's default), read at each send.
    static func config(_ option: ModelOption?) throws -> AgentConfig {
        var llm: LLMConfig
        if let option, let provider = LLMProviderStore.load().providers.first(where: { $0.id == option.provider }) {
            llm = provider.config
            llm.model = option.model
            if provider.needsKey, llm.apiKey?.isEmpty != false { throw LLMConfig.ConfigError.missingKey(provider.name) }
        } else {
            llm = try LLMConfig.load()
        }
        let model = llm.aiModel
        let search = AgentSettings.search
        let deepseekKey = LLMProviderStore.load().providers.first { $0.id == "deepseek" }?.apiKey
        let web = WebTools.setup(WebConfig(backend: search, deepseekKey: deepseekKey, tavilyKey: AgentSettings.tavilyKey), for: model)
        var options = llm.streamOptions
        options.hosted = web.hosted
        options.reasoning = AgentSettings.reasoning ? .medium : nil
        return AgentConfig(model: model, options: options,
                           systemPrompt: AgentPrompts.assistant(web: search != .off), tools: web.tools)
    }
}
