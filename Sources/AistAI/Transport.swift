import Foundation

/// Server-sent events over URLSession, one `data:` payload at a time.
enum SSE {
    struct HTTPError: Error {
        var status: Int
        var body: String
    }

    /// POSTs `body` and yields each `data:` line's payload. Throws `HTTPError` for non-2xx.
    static func post(_ url: URL, headers: [String: String], body: [String: Any]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    // Idle limit between bytes; a long answer can stream for minutes.
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 8000 { break } }
                        throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func object(_ payload: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
    }

    /// A readable message from an HTTP error body ({"error": {"message": …}} or raw text).
    static func describe(_ error: Error) -> String {
        if let e = error as? HTTPError {
            let obj = object(e.body)
            let msg = (obj?["error"] as? [String: Any])?["message"] as? String
                ?? obj?["message"] as? String
                ?? String(e.body.prefix(300))
            return "HTTP \(e.status)：\(msg)"
        }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet: return "没有网络连接"
            case .timedOut: return "请求超时"
            default: return u.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// Builds the partial message and the events that report it. Shared by every Api.
struct MessageBuilder {
    var message: AssistantMessage
    let model: Model
    private var toolArgs: [Int: String] = [:]

    init(model: Model) {
        self.model = model
        message = AssistantMessage(for: model)
    }

    mutating func startText() -> (Int, AssistantEvent) {
        message.content.append(.text(""))
        let i = message.content.count - 1
        return (i, .textStart(index: i, partial: message))
    }

    mutating func appendText(_ i: Int, _ delta: String) -> AssistantEvent {
        if case let .text(t) = message.content[i] { message.content[i] = .text(t + delta) }
        return .textDelta(index: i, delta: delta, partial: message)
    }

    mutating func startThinking(signature: String? = nil) -> (Int, AssistantEvent) {
        message.content.append(.thinking("", signature: signature))
        let i = message.content.count - 1
        return (i, .thinkingStart(index: i, partial: message))
    }

    mutating func appendThinking(_ i: Int, _ delta: String) -> AssistantEvent {
        if case let .thinking(t, s) = message.content[i] { message.content[i] = .thinking(t + delta, signature: s) }
        return .thinkingDelta(index: i, delta: delta, partial: message)
    }

    mutating func setSignature(_ i: Int, _ sig: String) {
        if case let .thinking(t, s) = message.content[i] { message.content[i] = .thinking(t, signature: (s ?? "") + sig) }
    }

    mutating func startToolCall(id: String, name: String) -> (Int, AssistantEvent) {
        message.content.append(.toolCall(ToolCall(id: id, name: name, arguments: .object([:]))))
        let i = message.content.count - 1
        toolArgs[i] = ""
        return (i, .toolCallStart(index: i, partial: message))
    }

    mutating func appendToolArgs(_ i: Int, _ delta: String) -> AssistantEvent {
        toolArgs[i, default: ""] += delta
        if case var .toolCall(c) = message.content[i] {
            c.arguments = JSONValue.parsePartial(toolArgs[i] ?? "")
            message.content[i] = .toolCall(c)
        }
        return .toolCallDelta(index: i, delta: delta, partial: message)
    }

    mutating func updateToolCall(_ i: Int, id: String?, name: String?) {
        guard case var .toolCall(c) = message.content[i] else { return }
        if let id, !id.isEmpty { c.id = id }
        if let name, !name.isEmpty { c.name = name }
        message.content[i] = .toolCall(c)
    }

    /// Closes block `i`, returning its end event.
    mutating func end(_ i: Int) -> AssistantEvent? {
        switch message.content[i] {
        case let .text(t): return .textEnd(index: i, content: t, partial: message)
        case let .thinking(t, _): return .thinkingEnd(index: i, content: t, partial: message)
        case var .toolCall(c):
            let raw = toolArgs[i] ?? ""
            c.arguments = raw.isEmpty ? .object([:]) : (JSONValue.parse(raw) ?? JSONValue.parsePartial(raw))
            message.content[i] = .toolCall(c)
            return .toolCallEnd(index: i, toolCall: c, partial: message)
        case .hosted: return nil
        }
    }

    mutating func finish(_ reason: StopReason) -> AssistantEvent {
        message.stopReason = reason
        message.usage.price(model.cost)
        return .done(reason: reason, message: message)
    }

    mutating func fail(_ error: Error) -> AssistantEvent {
        let aborted = error is CancellationError || (error as? URLError)?.code == .cancelled
        message.stopReason = aborted ? .aborted : .error
        message.errorMessage = aborted ? nil : SSE.describe(error)
        message.usage.price(model.cost)
        return .error(reason: message.stopReason, message: message)
    }
}
