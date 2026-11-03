import AistAI
import Foundation

/// Where web search comes from.
public enum SearchBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Provider's own search when the model has it, else DeepSeek API → Tavily → DuckDuckGo.
    case auto
    /// Run by the model provider (Anthropic, DeepSeek /anthropic).
    case hosted
    /// DeepSeek Search/Fetch API with the DeepSeek key.
    case deepseek
    case tavily
    case duckduckgo
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "自动"
        case .hosted: "模型自带"
        case .deepseek: "DeepSeek 搜索 API"
        case .tavily: "Tavily"
        case .duckduckgo: "DuckDuckGo"
        case .off: "关闭"
        }
    }
}

public struct WebConfig: Sendable {
    public var backend: SearchBackend
    public var deepseekKey: String?
    public var tavilyKey: String?
    public init(backend: SearchBackend = .auto, deepseekKey: String? = nil, tavilyKey: String? = nil) {
        self.backend = backend
        self.deepseekKey = deepseekKey
        self.tavilyKey = tavilyKey
    }
}

/// Builds the web tools for a model: which hosted tools to turn on, and which local ones to add.
public enum WebTools {
    public struct Setup: Sendable {
        public var hosted: Set<HostedTool>
        public var tools: [AgentTool]
    }

    public static func setup(_ config: WebConfig, for model: Model) -> Setup {
        let deepseek = config.deepseekKey.flatMap { $0.isEmpty ? nil : $0 }
        let tavily = config.tavilyKey.flatMap { $0.isEmpty ? nil : $0 }
        var backend = config.backend
        if backend == .auto {
            backend = model.hostedTools.contains(.webSearch) ? .hosted
                : deepseek != nil ? .deepseek : tavily != nil ? .tavily : .duckduckgo
        }
        let fetcher: Fetcher = deepseek.map { .deepseek($0) } ?? .native
        switch backend {
        case .off, .auto:
            return Setup(hosted: [], tools: [])
        case .hosted:
            let hosted = model.hostedTools.intersection([.webSearch, .webFetch])
            let tools = hosted.contains(.webFetch) ? [] : [fetchTool(fetcher)]
            return Setup(hosted: hosted, tools: tools)
        case .deepseek:
            guard let key = deepseek else { return setup(WebConfig(backend: .duckduckgo), for: model) }
            return Setup(hosted: [], tools: [searchTool(.deepseek(key)), fetchTool(fetcher)])
        case .tavily:
            guard let key = tavily else { return setup(WebConfig(backend: .duckduckgo, deepseekKey: deepseek), for: model) }
            return Setup(hosted: [], tools: [searchTool(.tavily(key)), fetchTool(fetcher)])
        case .duckduckgo:
            return Setup(hosted: [], tools: [searchTool(.duckduckgo), fetchTool(fetcher)])
        }
    }

    // MARK: - Tools

    enum Searcher: Sendable { case deepseek(String), tavily(String), duckduckgo }
    enum Fetcher: Sendable { case deepseek(String), native }

    static func searchTool(_ searcher: Searcher) -> AgentTool {
        AgentTool(
            name: "web_search", label: "搜索网页",
            description: "Search the web. Use for anything recent, factual or that you are unsure about. Returns titles, URLs and snippets; call fetch_page to read a result in full.",
            parameters: ["type": "object", "properties": ["query": ["type": "string", "description": "Search query"]], "required": ["query"]]
        ) { args in
            guard let query = args["query"]?.stringValue, !query.isEmpty else { return .init("缺少 query", isError: true) }
            let results: [WebSource]
            switch searcher {
            case let .deepseek(key): results = try await WebSearch.deepseek(query, key: key)
            case let .tavily(key): results = try await WebSearch.tavily(query, key: key)
            case .duckduckgo: results = try await WebSearch.duckduckgo(query)
            }
            guard !results.isEmpty else { return .init("没有搜索结果", details: ["sources": []]) }
            let text = results.enumerated().map { i, r in
                "[\(i + 1)] \(r.title)\n\(r.url)\n\(r.snippet ?? "")"
            }.joined(separator: "\n\n")
            return .init(text, details: ["query": .string(query), "sources": sourcesJSON(results)])
        }
    }

    static func fetchTool(_ fetcher: Fetcher) -> AgentTool {
        AgentTool(
            name: "fetch_page", label: "阅读网页",
            description: "Fetch a web page and return its main text as Markdown-ish plain text.",
            parameters: ["type": "object", "properties": ["url": ["type": "string", "description": "http(s) URL"]], "required": ["url"]]
        ) { args in
            guard let raw = args["url"]?.stringValue, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
                return .init("URL 无效", isError: true)
            }
            let page: WebPage
            switch fetcher {
            case let .deepseek(key):
                if let p = try? await WebFetch.deepseek(url, key: key) { page = p } else { page = try await WebFetch.native(url) }
            case .native:
                page = try await WebFetch.native(url)
            }
            let body = page.text.count > 15000 ? String(page.text.prefix(15000)) + "\n…（已截断）" : page.text
            return .init("# \(page.title)\n\(url.absoluteString)\n\n\(body)",
                         details: ["url": .string(url.absoluteString), "sources": sourcesJSON([WebSource(url: url.absoluteString, title: page.title)])])
        }
    }

    static func sourcesJSON(_ s: [WebSource]) -> JSONValue {
        .array(s.map { ["url": .string($0.url), "title": .string($0.title)] })
    }

    /// Sources recorded in a tool result's details.
    public static func sources(in details: JSONValue?) -> [WebSource] {
        guard case let .array(items)? = details?["sources"] else { return [] }
        return items.compactMap { item in
            guard let url = item["url"]?.stringValue else { return nil }
            return WebSource(url: url, title: item["title"]?.stringValue ?? url)
        }
    }
}
