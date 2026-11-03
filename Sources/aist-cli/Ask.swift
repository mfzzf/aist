import AistAI
import AistAgent
import AistCore
import Foundation

/// aist-cli ask "<question>" [--search auto|hosted|deepseek|tavily|duckduckgo|off] [--then "<follow-up>"] [--db <file>]
/// Streams the agent's events to stdout. Tavily key: $AIST_TAVILY_KEY.
func runAsk(_ args: [String], config: LLMConfig) async throws {
    func opt(_ name: String) -> String? {
        args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    let model = config.aiModel
    let backend = opt("--search").flatMap(SearchBackend.init(rawValue:)) ?? .auto
    let deepseekKey = config.provider == "deepseek" || model.baseURL.host?.hasSuffix("deepseek.com") == true ? config.apiKey : nil
    let web = WebTools.setup(WebConfig(backend: backend, deepseekKey: deepseekKey,
                                       tavilyKey: ProcessInfo.processInfo.environment["AIST_TAVILY_KEY"]), for: model)
    var options = config.streamOptions
    options.hosted = web.hosted
    let agent = AgentConfig(model: model, options: options,
                            systemPrompt: AgentPrompts.assistant(web: backend != .off), tools: web.tools)
    print("model: \(model.provider)/\(model.id) api=\(model.api.rawValue) hosted=\(web.hosted.map(\.rawValue)) tools=\(web.tools.map(\.tool.name))")

    var history: [Message] = []
    var questions = [args[2]]
    if let then = opt("--then") { questions.append(then) }
    let store = try opt("--db").map { try ConversationStore(url: URL(fileURLWithPath: $0)) }
    let conversation = try await store?.create(title: String(args[2].prefix(20)))

    for q in questions {
        print("\n>>> \(q)")
        let started = Date()
        for await event in AgentLoop.run(prompt: [.user(UserMessage(q))], history: history, config: agent) {
            switch event {
            case let .messageUpdate(e):
                switch e {
                case let .textDelta(_, d, _): print(d, terminator: ""); fflush(stdout)
                case let .thinkingDelta(_, d, _): print("\u{1B}[2m\(d)\u{1B}[0m", terminator: ""); fflush(stdout)
                case let .hostedStart(_, b, _): print("\n[hosted \(b.tool.rawValue)] \(b.detail)")
                case let .hostedEnd(_, b, _): print("[hosted done] \(b.sources.count) sources\(b.error.map { " error=\($0)" } ?? "")")
                case let .toolCallEnd(_, c, _): print("\n[call] \(c.name) \(c.arguments.jsonString)")
                case let .error(r, m): print("\n[\(r.rawValue)] \(m.errorMessage ?? "")")
                case let .done(r, m): print("\n[done \(r.rawValue)] in=\(m.usage.input) out=\(m.usage.output) cacheRead=\(m.usage.cacheRead)")
                default: break
                }
            case let .toolExecutionEnd(_, r):
                print("[result \(r.toolName)\(r.isError ? " ERROR" : "")] \(r.text.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))")
            case let .agentEnd(added):
                history += added
                if let store, let conversation { try await store.append(added, to: conversation.id) }
            default: break
            }
        }
        print(String(format: "--- %.1fs", Date().timeIntervalSince(started)))
    }
    if let store, let conversation {
        let back = try await store.messages(of: conversation.id)
        print("stored \(back.count) messages; search hit:", try await store.search(String(args[2].prefix(3))).map(\.title))
    }
}
