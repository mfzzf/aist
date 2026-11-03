import Foundation

/// POST {baseURL}/v1/messages with `stream: true` — Anthropic, and the /anthropic endpoints of
/// DeepSeek, Kimi, GLM… Hosted web search/fetch come back as server_tool_use + *_tool_result blocks.
public enum AnthropicMessages {
    public static func stream(_ model: Model, _ context: Context, _ options: StreamOptions) -> AssistantEventStream {
        AsyncStream { continuation in
            let task = Task {
                var b = MessageBuilder(model: model)
                continuation.yield(.start(partial: b.message))
                do {
                    let body = requestBody(model, context, options)
                    var headers = model.headers
                    headers["anthropic-version"] = "2023-06-01"
                    headers["x-api-key"] = options.apiKey ?? ""
                    var parser = StreamParser()
                    for try await payload in SSE.post(model.baseURL.appendingPathComponent("v1/messages"), headers: headers, body: body) {
                        try Task.checkCancellation()
                        guard let event = SSE.object(payload) else { continue }
                        for e in try parser.handle(event, &b) { continuation.yield(e) }
                        if parser.stopped { break }
                    }
                    try Task.checkCancellation()
                    continuation.yield(b.finish(parser.stopReason))
                } catch {
                    continuation.yield(b.fail(error))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    static func requestBody(_ model: Model, _ context: Context, _ options: StreamOptions) -> [String: Any] {
        var maxTokens = options.maxTokens ?? model.maxTokens
        var body: [String: Any] = [
            "model": model.id,
            "stream": true,
            "messages": convertMessages(context.messages),
        ]
        if let system = context.systemPrompt, !system.isEmpty { body["system"] = system }
        if let t = options.temperature { body["temperature"] = t }

        if let level = options.reasoning, model.reasoning {
            if model.compat.adaptiveThinking {
                body["thinking"] = ["type": "adaptive"]
            } else {
                let budget = switch level { case .low: 2048; case .medium: 8192; case .high: 16384 }
                maxTokens = max(maxTokens, budget + 2048)
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            }
        } else if model.compat.sendThinkingDisabled {
            body["thinking"] = ["type": "disabled"]
        }
        body["max_tokens"] = maxTokens

        var tools: [[String: Any]] = context.tools.map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.any]
        }
        let hosted = options.hosted.intersection(model.hostedTools)
        if hosted.contains(.webSearch), let type = model.compat.hostedSearchType {
            tools.append(["type": type, "name": "web_search", "max_uses": 5])
        }
        if hosted.contains(.webFetch), let type = model.compat.hostedFetchType {
            tools.append(["type": type, "name": "web_fetch", "max_uses": 5])
        }
        if !tools.isEmpty { body["tools"] = tools }
        return body
    }

    /// Neutral messages → Anthropic turns. Tool results ride in the next user turn, so consecutive
    /// same-role turns are merged (tool_result blocks stay first, as the API requires).
    static func convertMessages(_ messages: [Message]) -> [[String: Any]] {
        var turns: [(role: String, blocks: [[String: Any]])] = []
        func add(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if turns.last?.role == role { turns[turns.count - 1].blocks += blocks } else { turns.append((role, blocks)) }
        }
        for message in messages {
            switch message {
            case let .user(m):
                add("user", m.content.map(userBlock))
            case let .assistant(m):
                var blocks: [[String: Any]] = []
                for c in m.content {
                    switch c {
                    case let .text(t) where !t.isEmpty:
                        blocks.append(["type": "text", "text": t])
                    case let .thinking(t, sig?) where !sig.isEmpty:
                        blocks.append(["type": "thinking", "thinking": t, "signature": sig])
                    case let .toolCall(call):
                        let input: Any = if case .object = call.arguments { call.arguments.any } else { [String: Any]() }
                        blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                    case let .hosted(h):
                        blocks += h.raw.compactMap { $0.any as? [String: Any] }
                    default: break
                    }
                }
                add("assistant", blocks)
            case let .toolResult(r):
                var block: [String: Any] = [
                    "type": "tool_result", "tool_use_id": r.toolCallId,
                    "content": r.content.isEmpty ? [["type": "text", "text": "(empty)"]] : r.content.map(userBlock),
                ]
                if r.isError { block["is_error"] = true }
                add("user", [block])
            }
        }
        return turns.map { ["role": $0.role, "content": $0.blocks] }
    }

    private static func userBlock(_ c: UserContent) -> [String: Any] {
        switch c {
        case let .text(t): ["type": "text", "text": t.isEmpty ? " " : t]
        case let .image(i): ["type": "image", "source": ["type": "base64", "media_type": i.mimeType, "data": i.data.base64EncodedString()]]
        }
    }

    // MARK: - Response

    /// Anthropic stream events → neutral events. Pure apart from the builder, so tests can feed fixtures.
    struct StreamParser {
        /// Anthropic block index → our content index (nil for result blocks folded into a hosted block).
        private var blocks: [Int: Int] = [:]
        private var hostedJSON: [Int: String] = [:]
        private(set) var stopReason: StopReason = .stop
        private(set) var stopped = false

        struct ProviderError: LocalizedError {
            var message: String
            var errorDescription: String? { message }
        }

        mutating func handle(_ event: [String: Any], _ b: inout MessageBuilder) throws -> [AssistantEvent] {
            switch event["type"] as? String {
            case "message_start":
                if let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] { applyUsage(usage, &b) }
                return []
            case "content_block_start":
                guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return [] }
                return startBlock(index, block, &b)
            case "content_block_delta":
                guard let index = event["index"] as? Int, let i = blocks[index],
                      let delta = event["delta"] as? [String: Any] else { return [] }
                switch delta["type"] as? String {
                case "text_delta": return [b.appendText(i, delta["text"] as? String ?? "")]
                case "thinking_delta": return [b.appendThinking(i, delta["thinking"] as? String ?? "")]
                case "signature_delta": b.setSignature(i, delta["signature"] as? String ?? ""); return []
                case "input_json_delta":
                    let part = delta["partial_json"] as? String ?? ""
                    if case .hosted = b.message.content[i] { hostedJSON[i, default: ""] += part; return [] }
                    return [b.appendToolArgs(i, part)]
                default: return []
                }
            case "content_block_stop":
                guard let index = event["index"] as? Int, let i = blocks[index] else { return [] }
                if case var .hosted(h) = b.message.content[i] {
                    // The query is complete: the provider runs the search now.
                    let raw = hostedJSON[i] ?? ""
                    h.input = raw.isEmpty ? h.input : (JSONValue.parse(raw) ?? JSONValue.parsePartial(raw))
                    if case var .object(first)? = h.raw.first { first["input"] = h.input; h.raw[0] = .object(first) }
                    b.message.content[i] = .hosted(h)
                    return [.hostedStart(index: i, block: h, partial: b.message)]
                }
                return b.end(i).map { [$0] } ?? []
            case "message_delta":
                if let usage = event["usage"] as? [String: Any] { applyUsage(usage, &b) }
                if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String {
                    stopReason = switch reason {
                    case "max_tokens": .length
                    // pause_turn: a long server-tool turn; sending it back lets the model carry on.
                    case "tool_use", "pause_turn": .toolUse
                    default: .stop
                    }
                }
                return []
            case "message_stop":
                stopped = true
                return []
            case "error":
                let msg = (event["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
                throw ProviderError(message: msg)
            default:
                return []
            }
        }

        private mutating func startBlock(_ index: Int, _ block: [String: Any], _ b: inout MessageBuilder) -> [AssistantEvent] {
            switch block["type"] as? String {
            case "text":
                let (i, e) = b.startText()
                blocks[index] = i
                var events = [e]
                if let t = block["text"] as? String, !t.isEmpty { events.append(b.appendText(i, t)) }
                return events
            case "thinking":
                let (i, e) = b.startThinking(signature: block["signature"] as? String)
                blocks[index] = i
                return [e]
            case "tool_use":
                let (i, e) = b.startToolCall(id: block["id"] as? String ?? UUID().uuidString, name: block["name"] as? String ?? "")
                blocks[index] = i
                return [e]
            case "server_tool_use":
                let name = block["name"] as? String ?? ""
                let tool: HostedTool = name.contains("fetch") ? .webFetch : .webSearch
                var raw = JSONValue(any: block)
                if case var .object(o) = raw { o.removeValue(forKey: "caller"); raw = .object(o) }
                let h = HostedBlock(id: block["id"] as? String ?? "", tool: tool, input: JSONValue(any: block["input"]), raw: [raw])
                b.message.content.append(.hosted(h))
                blocks[index] = b.message.content.count - 1
                return []
            case let type? where type.hasSuffix("_tool_result"):
                // Folded into the hosted block it answers.
                guard let id = block["tool_use_id"] as? String,
                      let i = b.message.content.firstIndex(where: { if case let .hosted(h) = $0 { h.id == id } else { false } }),
                      case var .hosted(h) = b.message.content[i] else { return [] }
                h.raw.append(JSONValue(any: block))
                Self.readResult(block["content"], into: &h)
                h.done = true
                b.message.content[i] = .hosted(h)
                return [.hostedEnd(index: i, block: h, partial: b.message)]
            default:
                return []
            }
        }

        static func readResult(_ content: Any?, into h: inout HostedBlock) {
            if let items = content as? [[String: Any]] {
                h.sources = items.compactMap { item in
                    guard let url = item["url"] as? String else { return nil }
                    return WebSource(url: url, title: item["title"] as? String ?? url, snippet: item["page_age"] as? String)
                }
            } else if let obj = content as? [String: Any] {
                if let code = obj["error_code"] as? String {
                    h.error = code
                } else if let url = obj["url"] as? String {
                    let inner = obj["content"] as? [String: Any]
                    h.sources = [WebSource(url: url, title: inner?["title"] as? String ?? url)]
                }
            }
        }

        private func applyUsage(_ u: [String: Any], _ b: inout MessageBuilder) {
            if let v = u["input_tokens"] as? Int, v > 0 { b.message.usage.input = v }
            if let v = u["output_tokens"] as? Int, v > 0 { b.message.usage.output = v }
            if let v = u["cache_read_input_tokens"] as? Int, v > 0 { b.message.usage.cacheRead = v }
            if let v = u["cache_creation_input_tokens"] as? Int, v > 0 { b.message.usage.cacheWrite = v }
        }
    }
}
