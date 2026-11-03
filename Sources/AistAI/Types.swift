import Foundation

// A provider-neutral LLM layer modelled on pi-ai: an `Api` is a wire protocol, a `Model` is one
// catalog entry that names its Api, provider and quirks, and `AI.stream(model, context)` is the
// only call site. Everything above this layer (agent loop, storage, UI) speaks these types only.

/// Wire protocol. Several providers share one (DeepSeek, Kimi, GLM all speak Anthropic Messages).
public enum Api: String, Codable, Sendable, Hashable {
    case anthropicMessages = "anthropic-messages"
    case openaiCompletions = "openai-completions"
}

public enum InputKind: String, Codable, Sendable, Hashable { case text, image }

/// Tools the provider runs on its own servers.
public enum HostedTool: String, Codable, Sendable, Hashable, CaseIterable { case webSearch, webFetch }

/// USD per million tokens.
public struct Cost: Codable, Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public init(input: Double, output: Double, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// Per-provider deviations from the plain protocol. Kept as data so Api code has no vendor `if`s.
public struct Compat: Codable, Sendable, Hashable {
    /// Anthropic-compatible endpoints that think by default unless told `thinking: disabled`.
    public var sendThinkingDisabled = false
    /// `{"type": "adaptive"}` (current Claude) instead of `{"type": "enabled", "budget_tokens": n}`.
    public var adaptiveThinking = false
    /// Hosted tool `type` strings, e.g. "web_search_20260318".
    public var hostedSearchType: String?
    public var hostedFetchType: String?
    /// OpenAI-compatible servers that stream reasoning as `delta.reasoning_content` and want it echoed back.
    public var reasoningContent = false

    public init(sendThinkingDisabled: Bool = false, adaptiveThinking: Bool = false,
                hostedSearchType: String? = nil, hostedFetchType: String? = nil, reasoningContent: Bool = false) {
        self.sendThinkingDisabled = sendThinkingDisabled
        self.adaptiveThinking = adaptiveThinking
        self.hostedSearchType = hostedSearchType
        self.hostedFetchType = hostedFetchType
        self.reasoningContent = reasoningContent
    }
}

public struct Model: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var api: Api
    /// Provider id ("deepseek", "anthropic", …): decides whether provider-specific blocks can be replayed.
    public var provider: String
    public var baseURL: URL
    public var reasoning: Bool
    public var input: Set<InputKind>
    public var contextWindow: Int
    public var maxTokens: Int
    public var cost: Cost?
    public var hostedTools: Set<HostedTool>
    public var compat: Compat
    public var headers: [String: String]

    public init(id: String, name: String? = nil, api: Api, provider: String, baseURL: URL,
                reasoning: Bool = false, input: Set<InputKind> = [.text], contextWindow: Int = 128_000,
                maxTokens: Int = 8192, cost: Cost? = nil, hostedTools: Set<HostedTool> = [],
                compat: Compat = Compat(), headers: [String: String] = [:]) {
        self.id = id
        self.name = name ?? id
        self.api = api
        self.provider = provider
        self.baseURL = baseURL
        self.reasoning = reasoning
        self.input = input
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.cost = cost
        self.hostedTools = hostedTools
        self.compat = compat
        self.headers = headers
    }
}

// MARK: - Messages

public struct ImageContent: Codable, Sendable, Hashable {
    public var data: Data
    public var mimeType: String
    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// What a user (or a tool result) can say.
public enum UserContent: Sendable, Hashable {
    case text(String)
    case image(ImageContent)
}

public struct ToolCall: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct WebSource: Codable, Sendable, Hashable, Identifiable {
    public var url: String
    public var title: String
    public var snippet: String?
    public var id: String { url }
    public init(url: String, title: String, snippet: String? = nil) {
        self.url = url
        self.title = title
        self.snippet = snippet
    }

    public var host: String {
        let h = URL(string: url)?.host ?? url
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

/// A provider-run tool call and its result, e.g. Anthropic's server_tool_use + web_search_tool_result.
public struct HostedBlock: Codable, Sendable, Hashable {
    public var id: String
    public var tool: HostedTool
    public var input: JSONValue
    public var sources: [WebSource]
    public var error: String?
    public var done: Bool
    /// The provider's original blocks, replayed verbatim to the same provider (they carry encrypted content).
    public var raw: [JSONValue]

    public init(id: String, tool: HostedTool, input: JSONValue = .object([:]), sources: [WebSource] = [],
                error: String? = nil, done: Bool = false, raw: [JSONValue] = []) {
        self.id = id
        self.tool = tool
        self.input = input
        self.sources = sources
        self.error = error
        self.done = done
        self.raw = raw
    }

    /// The query or URL, for "正在搜索 …" lines.
    public var detail: String {
        input["query"]?.stringValue ?? input["url"]?.stringValue ?? ""
    }
}

public enum AssistantContent: Sendable, Hashable {
    case text(String)
    case thinking(String, signature: String?)
    case toolCall(ToolCall)
    case hosted(HostedBlock)
}

public enum StopReason: String, Codable, Sendable, Hashable {
    case stop, length, toolUse, error, aborted
}

public struct Usage: Codable, Sendable, Hashable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    /// USD, from the model's catalog price.
    public var cost = 0.0
    public init() {}

    mutating func price(_ c: Cost?) {
        guard let c else { return }
        cost = (Double(input) * c.input + Double(output) * c.output
            + Double(cacheRead) * c.cacheRead + Double(cacheWrite) * c.cacheWrite) / 1_000_000
    }
}

public struct UserMessage: Codable, Sendable, Hashable {
    public var content: [UserContent]
    public var timestamp: Date
    public init(_ content: [UserContent], timestamp: Date = .now) {
        self.content = content
        self.timestamp = timestamp
    }
    public init(_ text: String) { self.init([.text(text)]) }
}

public struct AssistantMessage: Codable, Sendable, Hashable {
    public var content: [AssistantContent]
    public var api: Api
    public var provider: String
    public var model: String
    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?
    public var timestamp: Date

    public init(content: [AssistantContent] = [], api: Api, provider: String, model: String,
                usage: Usage = Usage(), stopReason: StopReason = .stop, errorMessage: String? = nil, timestamp: Date = .now) {
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }

    public init(for model: Model) {
        self.init(api: model.api, provider: model.provider, model: model.id)
    }

    public var text: String {
        content.compactMap { if case let .text(t) = $0 { t } else { nil } }.joined()
    }

    public var toolCalls: [ToolCall] {
        content.compactMap { if case let .toolCall(c) = $0 { c } else { nil } }
    }
}

public struct ToolResultMessage: Codable, Sendable, Hashable {
    public var toolCallId: String
    public var toolName: String
    public var content: [UserContent]
    public var isError: Bool
    /// Not sent to the model: what the UI shows (e.g. the pages a search found).
    public var details: JSONValue?
    public var timestamp: Date

    public init(toolCallId: String, toolName: String, content: [UserContent], isError: Bool = false,
                details: JSONValue? = nil, timestamp: Date = .now) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.isError = isError
        self.details = details
        self.timestamp = timestamp
    }

    public var text: String {
        content.compactMap { if case let .text(t) = $0 { t } else { nil } }.joined(separator: "\n")
    }
}

public enum Message: Sendable, Hashable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    public var timestamp: Date {
        switch self {
        case let .user(m): m.timestamp
        case let .assistant(m): m.timestamp
        case let .toolResult(m): m.timestamp
        }
    }
}

public struct Tool: Sendable, Hashable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments.
    public var parameters: JSONValue
    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct Context: Sendable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [Tool]
    public init(systemPrompt: String? = nil, messages: [Message] = [], tools: [Tool] = []) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

public enum ReasoningLevel: String, Codable, Sendable { case low, medium, high }

public struct StreamOptions: Sendable {
    public var apiKey: String?
    public var maxTokens: Int?
    /// nil = no thinking.
    public var reasoning: ReasoningLevel?
    /// Provider-run tools to enable; ignored for ones the model doesn't list in `hostedTools`.
    public var hosted: Set<HostedTool>
    public var temperature: Double?

    public init(apiKey: String? = nil, maxTokens: Int? = nil, reasoning: ReasoningLevel? = nil,
                hosted: Set<HostedTool> = [], temperature: Double? = nil) {
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.hosted = hosted
        self.temperature = temperature
    }
}

// MARK: - Events

/// One streaming step. Every event but `done`/`error` carries the message built so far.
public enum AssistantEvent: Sendable {
    case start(partial: AssistantMessage)
    case textStart(index: Int, partial: AssistantMessage)
    case textDelta(index: Int, delta: String, partial: AssistantMessage)
    case textEnd(index: Int, content: String, partial: AssistantMessage)
    case thinkingStart(index: Int, partial: AssistantMessage)
    case thinkingDelta(index: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(index: Int, content: String, partial: AssistantMessage)
    case toolCallStart(index: Int, partial: AssistantMessage)
    case toolCallDelta(index: Int, delta: String, partial: AssistantMessage)
    case toolCallEnd(index: Int, toolCall: ToolCall, partial: AssistantMessage)
    case hostedStart(index: Int, block: HostedBlock, partial: AssistantMessage)
    case hostedEnd(index: Int, block: HostedBlock, partial: AssistantMessage)
    case done(reason: StopReason, message: AssistantMessage)
    /// `reason` is `.error` or `.aborted`; `message` keeps whatever streamed before.
    case error(reason: StopReason, message: AssistantMessage)

    public var partial: AssistantMessage {
        switch self {
        case let .start(p), let .textStart(_, p), let .textDelta(_, _, p), let .textEnd(_, _, p),
             let .thinkingStart(_, p), let .thinkingDelta(_, _, p), let .thinkingEnd(_, _, p),
             let .toolCallStart(_, p), let .toolCallDelta(_, _, p), let .toolCallEnd(_, _, p),
             let .hostedStart(_, _, p), let .hostedEnd(_, _, p), let .done(_, p), let .error(_, p): p
        }
    }
}

public typealias AssistantEventStream = AsyncStream<AssistantEvent>

extension AsyncStream where Element == AssistantEvent {
    /// Drains the stream and returns the final message (errors included, as `stopReason`).
    public func result() async -> AssistantMessage? {
        var last: AssistantMessage?
        for await event in self {
            switch event {
            case let .done(_, m), let .error(_, m): return m
            default: last = event.partial
            }
        }
        return last
    }
}
