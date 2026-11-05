import AistAI
import Foundation

/// A tool the agent runs locally. `execute` gets the parsed arguments and returns what the model reads
/// (`content`) plus anything the UI wants to show (`details`, e.g. the pages a search found).
public struct AgentTool: Sendable {
    public struct Output: Sendable {
        public var content: [UserContent]
        public var details: JSONValue?
        public var isError: Bool
        public init(_ text: String, details: JSONValue? = nil, isError: Bool = false) {
            content = [.text(text)]
            self.details = details
            self.isError = isError
        }
        public init(content: [UserContent], details: JSONValue? = nil, isError: Bool = false) {
            self.content = content
            self.details = details
            self.isError = isError
        }
    }

    public var tool: Tool
    /// Short verb phrase for status lines, e.g. "搜索网页".
    public var label: String
    public var execute: @Sendable (_ args: JSONValue) async throws -> Output

    public init(name: String, label: String, description: String, parameters: JSONValue,
                execute: @escaping @Sendable (_ args: JSONValue) async throws -> Output) {
        tool = Tool(name: name, description: description, parameters: parameters)
        self.label = label
        self.execute = execute
    }
}

public struct AgentConfig: Sendable {
    public var model: Model
    public var options: StreamOptions
    public var systemPrompt: String?
    public var tools: [AgentTool]
    /// nil: no limit — the run ends when the model stops calling tools, or is cancelled.
    public var maxTurns: Int?

    public init(model: Model, options: StreamOptions = StreamOptions(), systemPrompt: String? = nil,
                tools: [AgentTool] = [], maxTurns: Int? = nil) {
        self.model = model
        self.options = options
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.maxTurns = maxTurns
    }
}

public enum AgentEvent: Sendable {
    case agentStart
    case turnStart
    /// A complete message joined the transcript (the prompt, a finished assistant turn, a tool result).
    case message(Message)
    /// The assistant message being streamed.
    case messageUpdate(AssistantEvent)
    case toolExecutionStart(toolCallId: String, name: String, args: JSONValue)
    case toolExecutionEnd(toolCallId: String, result: ToolResultMessage)
    case turnEnd
    /// Everything added this run, in order.
    case agentEnd(newMessages: [Message])
}

/// The loop: stream an answer → run the tools it called → feed results back → repeat until the
/// model stops calling tools. Knows nothing about UI or storage; cancel by cancelling iteration.
public enum AgentLoop {
    public static func run(prompt: [Message], history: [Message], config: AgentConfig) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                var messages = history
                var added: [Message] = []
                func add(_ m: Message) {
                    messages.append(m)
                    added.append(m)
                    continuation.yield(.message(m))
                }
                continuation.yield(.agentStart)
                prompt.forEach(add)

                let byName = Dictionary(config.tools.map { ($0.tool.name, $0) }, uniquingKeysWith: { a, _ in a })
                var turns = 0
                while config.maxTurns.map({ turns < $0 }) ?? true, !Task.isCancelled {
                    turns += 1
                    continuation.yield(.turnStart)
                    let context = Context(systemPrompt: config.systemPrompt, messages: messages, tools: config.tools.map(\.tool))
                    var final: AssistantMessage?
                    for await event in AI.stream(config.model, context, config.options) {
                        continuation.yield(.messageUpdate(event))
                        if case let .done(_, m) = event { final = m }
                        if case let .error(_, m) = event { final = m }
                    }
                    if Task.isCancelled, final?.stopReason != .aborted {
                        final?.stopReason = .aborted
                    }
                    guard let answer = final else { break }
                    add(.assistant(answer))
                    guard answer.stopReason == .toolUse, !Task.isCancelled else {
                        continuation.yield(.turnEnd)
                        break
                    }

                    // Run this turn's calls concurrently; results go back in call order.
                    let calls = answer.toolCalls
                    for call in calls {
                        continuation.yield(.toolExecutionStart(toolCallId: call.id, name: call.name, args: call.arguments))
                    }
                    let results = await withTaskGroup(of: (Int, ToolResultMessage).self) { group in
                        for (i, call) in calls.enumerated() {
                            group.addTask { (i, await execute(call, byName[call.name])) }
                        }
                        var out = [ToolResultMessage?](repeating: nil, count: calls.count)
                        for await (i, r) in group {
                            out[i] = r
                            continuation.yield(.toolExecutionEnd(toolCallId: r.toolCallId, result: r))
                        }
                        return out.compactMap { $0 }
                    }
                    results.forEach { add(.toolResult($0)) }
                    continuation.yield(.turnEnd)
                    if Task.isCancelled { break }
                }
                continuation.yield(.agentEnd(newMessages: added))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func execute(_ call: ToolCall, _ tool: AgentTool?) async -> ToolResultMessage {
        guard let tool else {
            return ToolResultMessage(toolCallId: call.id, toolName: call.name,
                                     content: [.text("没有名为 \(call.name) 的工具")], isError: true)
        }
        do {
            try Task.checkCancellation()
            let out = try await tool.execute(call.arguments)
            return ToolResultMessage(toolCallId: call.id, toolName: call.name, content: out.content,
                                     isError: out.isError, details: out.details)
        } catch is CancellationError {
            return ToolResultMessage(toolCallId: call.id, toolName: call.name, content: [.text("已取消")], isError: true)
        } catch {
            return ToolResultMessage(toolCallId: call.id, toolName: call.name,
                                     content: [.text("出错：\(error.localizedDescription)")], isError: true)
        }
    }
}
