import Foundation

/// POST {baseURL}/responses with `stream: true` — OpenAI's Responses API and the servers that
/// copy it (AstraFlow serves its DeepSeek models this way). Stateless: `store: false`, the whole
/// history goes in `input` every turn.
public enum OpenAIResponses {
    public static func stream(_ model: Model, _ context: Context, _ options: StreamOptions) -> AssistantEventStream {
        AsyncStream { continuation in
            let task = Task {
                var b = MessageBuilder(model: model)
                continuation.yield(.start(partial: b.message))
                do {
                    var headers = model.headers
                    if let key = options.apiKey, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
                    var parser = StreamParser()
                    let url = model.baseURL.appendingPathComponent("responses")
                    for try await payload in SSE.post(url, headers: headers, body: requestBody(model, context, options)) {
                        try Task.checkCancellation()
                        guard let event = SSE.object(payload) else { continue }
                        for e in try parser.handle(event, &b) { continuation.yield(e) }
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
        var input: [[String: Any]] = []
        for message in context.messages {
            switch message {
            case let .user(m):
                input.append(["role": "user", "content": m.content.map(part)])
            case let .assistant(m):
                for c in m.content {
                    switch c {
                    case let .text(t) where !t.isEmpty:
                        input.append(["type": "message", "role": "assistant",
                                      "content": [["type": "output_text", "text": t]]])
                    case let .toolCall(call):
                        input.append(["type": "function_call", "call_id": call.id, "name": call.name,
                                      "arguments": call.arguments.jsonString])
                    default:
                        // Reasoning items can't be replayed without the provider's encrypted content;
                        // the model doesn't need them to continue.
                        break
                    }
                }
            case let .toolResult(r):
                input.append(["type": "function_call_output", "call_id": r.toolCallId,
                              "output": r.text.isEmpty ? "(empty)" : r.text])
            }
        }
        var body: [String: Any] = [
            "model": model.id,
            "stream": true,
            "store": false,
            "input": input,
            "max_output_tokens": options.maxTokens ?? model.maxTokens,
        ]
        if let system = context.systemPrompt, !system.isEmpty { body["instructions"] = system }
        if let t = options.temperature { body["temperature"] = t }
        if model.reasoning {
            if let level = options.reasoning {
                body["reasoning"] = ["effort": level.rawValue, "summary": "auto"]
            } else if model.compat.reasoningEffortNone {
                body["reasoning"] = ["effort": "none"]
            }
        }
        if !context.tools.isEmpty {
            body["tools"] = context.tools.map {
                ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters.any]
            }
        }
        return body
    }

    private static func part(_ c: UserContent) -> [String: Any] {
        switch c {
        case let .text(t): ["type": "input_text", "text": t]
        case let .image(i): ["type": "input_image", "image_url": "data:\(i.mimeType);base64,\(i.data.base64EncodedString())"]
        }
    }

    /// Responses events → neutral events. Each output item (reasoning, message, function_call) has
    /// an `output_index`; deltas name it, and `output_item.done` closes it.
    struct StreamParser {
        /// output_index → our content index.
        private var blocks: [Int: Int] = [:]
        /// Function calls whose arguments arrived as deltas (else `arguments.done` carries them whole).
        private var streamedArgs: Set<Int> = []
        private(set) var stopReason: StopReason = .stop

        mutating func handle(_ event: [String: Any], _ b: inout MessageBuilder) throws -> [AssistantEvent] {
            let type = event["type"] as? String ?? ""
            let index = event["output_index"] as? Int ?? 0
            switch type {
            case "response.output_item.added":
                guard let item = event["item"] as? [String: Any] else { return [] }
                switch item["type"] as? String {
                case "function_call":
                    let id = item["call_id"] as? String ?? item["id"] as? String ?? "call_\(index)"
                    let (i, e) = b.startToolCall(id: id, name: item["name"] as? String ?? "")
                    blocks[index] = i
                    var events = [e]
                    if let args = item["arguments"] as? String, !args.isEmpty {
                        streamedArgs.insert(index)
                        events.append(b.appendToolArgs(i, args))
                    }
                    return events
                case "reasoning":
                    let (i, e) = b.startThinking()
                    blocks[index] = i
                    return [e]
                default:
                    // Messages start their text block on the first delta.
                    return []
                }

            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
                if let i = blocks[index], case .thinking = b.message.content[i] {
                    return [b.appendThinking(i, delta)]
                }
                let (i, e) = b.startThinking()
                blocks[index] = i
                return [e, b.appendThinking(i, delta)]

            case "response.reasoning_summary_part.added":
                // A second summary paragraph in the same item.
                if let i = blocks[index], case let .thinking(t, _) = b.message.content[i], !t.isEmpty {
                    return [b.appendThinking(i, "\n\n")]
                }
                return []

            case "response.output_text.delta", "response.refusal.delta":
                guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
                if let i = blocks[index], case .text = b.message.content[i] {
                    return [b.appendText(i, delta)]
                }
                var events: [AssistantEvent] = []
                if let i = blocks[index], let e = b.end(i) { events.append(e) }
                let (i, e) = b.startText()
                blocks[index] = i
                return events + [e, b.appendText(i, delta)]

            case "response.function_call_arguments.delta":
                guard let i = blocks[index], let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
                streamedArgs.insert(index)
                return [b.appendToolArgs(i, delta)]

            case "response.function_call_arguments.done":
                guard let i = blocks[index], !streamedArgs.contains(index),
                      let args = event["arguments"] as? String, !args.isEmpty else { return [] }
                streamedArgs.insert(index)
                return [b.appendToolArgs(i, args)]

            case "response.output_item.done":
                guard let i = blocks.removeValue(forKey: index) else { return [] }
                if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call" {
                    b.updateToolCall(i, id: item["call_id"] as? String, name: item["name"] as? String)
                    if !streamedArgs.contains(index), let args = item["arguments"] as? String, !args.isEmpty {
                        _ = b.appendToolArgs(i, args)
                    }
                }
                return b.end(i).map { [$0] } ?? []

            case "response.completed", "response.incomplete":
                let response = event["response"] as? [String: Any] ?? [:]
                readUsage(response, &b)
                if type == "response.incomplete" {
                    let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
                    stopReason = reason == "content_filter" ? .stop : .length
                }
                return []

            case "response.failed":
                let response = event["response"] as? [String: Any] ?? [:]
                let message = (response["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
                throw AnthropicMessages.StreamParser.ProviderError(message: message)

            case "error":
                let message = event["message"] as? String
                    ?? (event["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
                throw AnthropicMessages.StreamParser.ProviderError(message: message)

            default:
                if let err = event["error"] as? [String: Any], type.isEmpty {
                    throw AnthropicMessages.StreamParser.ProviderError(message: err["message"] as? String ?? "未知错误")
                }
                return []
            }
        }

        private func readUsage(_ response: [String: Any], _ b: inout MessageBuilder) {
            guard let usage = response["usage"] as? [String: Any] else { return }
            let cached = (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            b.message.usage.input = (usage["input_tokens"] as? Int ?? 0) - cached
            b.message.usage.cacheRead = cached
            b.message.usage.output = usage["output_tokens"] as? Int ?? 0
        }

        /// Closes whatever the stream left open (a dropped connection, a server that skips `.done`).
        mutating func close(_ b: inout MessageBuilder) -> [AssistantEvent] {
            var events: [AssistantEvent] = []
            for i in blocks.values.sorted() { if let e = b.end(i) { events.append(e) } }
            blocks = [:]
            if !b.message.toolCalls.isEmpty, stopReason == .stop { stopReason = .toolUse }
            return events
        }
    }
}
