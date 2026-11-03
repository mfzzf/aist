import Foundation

/// What we know about models beyond their id: capabilities, quirks and price.
/// Unknown models get conservative defaults for their protocol.
public enum Catalog {
    public static func model(id: String, provider: String, api: Api, baseURL: URL, name: String? = nil) -> Model {
        let host = baseURL.host ?? ""
        var m = Model(id: id, name: name, api: api, provider: provider, baseURL: baseURL)

        switch api {
        case .anthropicMessages:
            if host.hasSuffix("anthropic.com") {
                // Current Claude: adaptive thinking, rejects `thinking: disabled`.
                let older = id.contains("claude-3") || id.range(of: #"-4-[0-5]\b|-4-[0-5]-|-4-20"#, options: .regularExpression) != nil
                m.reasoning = true
                m.input = [.text, .image]
                m.contextWindow = 200_000
                m.maxTokens = 16_000
                m.hostedTools = [.webSearch, .webFetch]
                m.compat = Compat(adaptiveThinking: !older,
                                  hostedSearchType: older ? "web_search_20250305" : "web_search_20260318",
                                  hostedFetchType: older ? "web_fetch_20250910" : "web_fetch_20260318")
            } else if host.hasSuffix("deepseek.com") {
                // /anthropic thinks unless told not to; web_search runs server-side (verified 2026-11-03).
                m.reasoning = true
                m.contextWindow = 128_000
                m.maxTokens = 8192
                m.hostedTools = [.webSearch]
                m.compat = Compat(sendThinkingDisabled: true, hostedSearchType: "web_search_20250305")
            } else {
                // Kimi, GLM, MiniMax… /anthropic endpoints.
                m.reasoning = true
                m.compat = Compat(sendThinkingDisabled: true)
            }
        case .openaiCompletions:
            let reasoningContent = host.contains("deepseek") || host.contains("moonshot") || host.contains("dashscope")
                || host.contains("modelverse")
            m.compat = Compat(reasoningContent: reasoningContent)
            m.reasoning = id.contains("reason") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.contains("thinking")
            if id.hasPrefix("gpt-4o") || id.hasPrefix("gpt-5") || id.contains("vl") || id.contains("vision") {
                m.input = [.text, .image]
            }
        }

        if let cost = prices[id] { m.cost = cost }
        return m
    }

    /// USD per million tokens. Empty until prices are checked against the providers' pages —
    /// a wrong number is worse than none.
    static let prices: [String: Cost] = [:]
}
