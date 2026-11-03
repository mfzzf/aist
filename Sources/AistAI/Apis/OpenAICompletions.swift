import Foundation

/// POST {baseURL}/chat/completions with `stream: true` — OpenAI and everything compatible
/// (OpenRouter, Ollama, Qwen, AstraFlow…). No hosted tools on this protocol.
public enum OpenAICompletions {
    public static func stream(_ model: Model, _ context: Context, _ options: StreamOptions) -> AssistantEventStream {
        AsyncStream { continuation in
            let task = Task {
                var b = MessageBuilder(model: model)
                continuation.yield(.start(partial: b.message))
                do {
                    var headers = model.headers
                    if let key = options.apiKey, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
                    var parser = StreamParser()
                    let url = model.baseURL.appendingPathComponent("chat/completions")
                    for try await payload in SSE.post(url, headers: headers, body: requestBody(model, context, options)) {
                        try Task.checkCancellation()
                        guard let chunk = SSE.object(payload) else { continue }
                        for e in try parser.handle(chunk, &b) { continuation.yield(e) }
                    }
                    try Task.checkCancellation()
                    for e in parser.close(&b) { continuation.yield(e) }
                    continuation.yield(b.finish(parser.stopReason))
                } catch {
                    continuation.yield(b.fail(error))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func requestBody(_ model: Model, _ context: Context, _ options: StreamOptions) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let system = context.systemPrompt, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        for message in context.messages {
            switch message {
            case let .user(m):
                if m.content.count == 1, case let .text(t) = m.content[0] {
                    messages.append(["role": "user", "content": t])
                } else {
                    messages.append(["role": "user", "content": m.content.map(part)])
                }
            case let .assistant(m):
                var out: [String: Any] = ["role": "assistant"]
                let text = m.text
                out["content"] = text.isEmpty ? NSNull() : text
                let calls = m.toolCalls
                if !calls.isEmpty {
                    out["tool_calls"] = calls.map {
                        ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments.jsonString]]
                    }
                }
                if model.compat.reasoningContent {
                    let thinking = m.content.compactMap { if case let .thinking(t, _) = $0 { t } else { nil } }.joined()
                    if !thinking.isEmpty { out["reasoning_content"] = thinking }
                }
                guard !text.isEmpty || !calls.isEmpty else { continue }
                messages.append(out)
            case let .toolResult(r):
                messages.append(["role": "tool", "tool_call_id": r.toolCallId, "content": r.text.isEmpty ? "(empty)" : r.text])
            }
        }
        var body: [String: Any] = [
            "model": model.id,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages,
            "max_tokens": options.maxTokens ?? model.maxTokens,
        ]
        if let t = options.temperature { body["temperature"] = t }
        if let level = options.reasoning, model.reasoning { body["reasoning_effort"] = level.rawValue }
        if !context.tools.isEmpty {
            body["tools"] = context.tools.map {
                ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters.any]]
            }
        }
        return body
    }

    private static func part(_ c: UserContent) -> [String: Any] {
        switch c {
        case let .text(t): ["type": "text", "text": t]
        case let .image(i): ["type": "image_url", "image_url": ["url": "data:\(i.mimeType);base64,\(i.data.base64EncodedString())"]]
        }
    }

    /// Chat-completion chunks → neutral events. Text, reasoning and tool calls interleave freely in
    /// deltas, so a block closes whenever the kind changes.
    struct StreamParser {
        private enum Open { case text(Int), thinking(Int) }
        private var open: Open?
        /// tool_calls[].index → our content index.
        private var tools: [Int: Int] = [:]
        private(set) var stopReason: StopReason = .stop

        mutating func handle(_ chunk: [String: Any], _ b: inout MessageBuilder) throws -> [AssistantEvent] {
            if let err = chunk["error"] as? [String: Any] {
                throw AnthropicMessages.StreamParser.ProviderError(message: err["message"] as? String ?? "未知错误")
            }
            if let usage = chunk["usage"] as? [String: Any] {
                let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
                b.message.usage.input = (usage["prompt_tokens"] as? Int ?? 0) - cached
                b.message.usage.cacheRead = cached
                b.message.usage.output = usage["completion_tokens"] as? Int ?? 0
            }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return [] }
            var events: [AssistantEvent] = []
            let delta = choice["delta"] as? [String: Any] ?? [:]

            let reasoning = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String
            if let r = reasoning, !r.isEmpty {
                if case let .thinking(i) = open {
                    events.append(b.appendThinking(i, r))
                } else {
                    events += closeOpen(&b)
                    let (i, e) = b.startThinking()
                    open = .thinking(i)
                    events += [e, b.appendThinking(i, r)]
                }
            }
            if let t = delta["content"] as? String, !t.isEmpty {
                if case let .text(i) = open {
                    events.append(b.appendText(i, t))
                } else {
                    events += closeOpen(&b)
                    let (i, e) = b.startText()
                    open = .text(i)
                    events += [e, b.appendText(i, t)]
                }
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let k = call["index"] as? Int ?? 0
                let fn = call["function"] as? [String: Any] ?? [:]
                if tools[k] == nil {
                    events += closeOpen(&b)
                    let (i, e) = b.startToolCall(id: call["id"] as? String ?? "call_\(k)", name: fn["name"] as? String ?? "")
                    tools[k] = i
                    events.append(e)
                } else if let i = tools[k] {
                    b.updateToolCall(i, id: call["id"] as? String, name: fn["name"] as? String)
                }
                if let args = fn["arguments"] as? String, !args.isEmpty, let i = tools[k] {
                    events.append(b.appendToolArgs(i, args))
                }
            }
            if let reason = choice["finish_reason"] as? String {
                stopReason = switch reason {
                case "length": .length
                case "tool_calls", "function_call": .toolUse
                default: .stop
                }
            }
            return events
        }

        private mutating func closeOpen(_ b: inout MessageBuilder) -> [AssistantEvent] {
            defer { open = nil }
            switch open {
            case let .text(i), let .thinking(i): return b.end(i).map { [$0] } ?? []
            case nil: return []
            }
        }

        mutating func close(_ b: inout MessageBuilder) -> [AssistantEvent] {
            var events = closeOpen(&b)
            for i in tools.values.sorted() { if let e = b.end(i) { events.append(e) } }
            tools = [:]
            if !b.message.toolCalls.isEmpty, stopReason == .stop { stopReason = .toolUse }
            return events
        }
    }
}
