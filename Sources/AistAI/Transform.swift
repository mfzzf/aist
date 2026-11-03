import Foundation

/// Makes a history safe to send to `model`, whoever produced it (pi-ai's context hand-off):
/// - another provider's thinking, signatures and hosted-tool blocks can't be replayed → plain text;
/// - tool-call ids are normalised to `[A-Za-z0-9_-]{1,64}` and results renamed to match;
/// - a tool call left without a result (aborted turn) gets a synthetic error result;
/// - failed/aborted turns with nothing in them are dropped.
public enum Transform {
    public static func prepare(_ messages: [Message], for model: Model) -> [Message] {
        var ids: [String: String] = [:]
        func normalise(_ id: String) -> String {
            if let n = ids[id] { return n }
            var n = String(id.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" ? Character($0) : "_"
            })
            if n.isEmpty { n = "call" }
            if n.count > 64 { n = String(n.suffix(64)) }
            ids[id] = n
            return n
        }

        let answered = Set(messages.compactMap { if case let .toolResult(r) = $0 { r.toolCallId } else { nil } })
        var out: [Message] = []
        for message in messages {
            switch message {
            case var .assistant(m):
                let same = m.api == model.api && m.provider == model.provider && m.model == model.id
                let sameProvider = m.api == model.api && m.provider == model.provider
                var content: [AssistantContent] = []
                for c in m.content {
                    switch c {
                    case let .text(t):
                        if !t.isEmpty { content.append(.text(t)) }
                    case let .thinking(t, sig):
                        if same, sig?.isEmpty == false { content.append(.thinking(t, signature: sig)) }
                        else if !same, !t.isEmpty { content.append(.text("<thinking>\n\(t)\n</thinking>")) }
                        // Same model but unsigned (DeepSeek-style): can't be replayed and isn't needed.
                    case var .toolCall(call):
                        call.id = normalise(call.id)
                        content.append(.toolCall(call))
                    case let .hosted(h):
                        if sameProvider, h.done, !h.raw.isEmpty {
                            content.append(.hosted(h))
                        } else if !h.sources.isEmpty {
                            let list = h.sources.prefix(8).map { "- \($0.title) <\($0.url)>" }.joined(separator: "\n")
                            let label = h.tool == .webSearch ? "联网搜索「\(h.detail)」的结果" : "已读取网页"
                            content.append(.text("[\(label)]\n\(list)"))
                        }
                    }
                }
                if (m.stopReason == .error || m.stopReason == .aborted), content.isEmpty { continue }
                // Hosted blocks that never got their result can't be replayed.
                m.content = content
                out.append(.assistant(m))
                for call in m.toolCalls where !answered.contains(where: { normalise($0) == call.id }) {
                    out.append(.toolResult(ToolResultMessage(
                        toolCallId: call.id, toolName: call.name,
                        content: [.text("工具没有执行（回答被中断）")], isError: true
                    )))
                }
            case var .toolResult(r):
                r.toolCallId = normalise(r.toolCallId)
                if !model.input.contains(.image) {
                    r.content = r.content.map { if case .image = $0 { .text("[图片]") } else { $0 } }
                }
                out.append(.toolResult(r))
            case var .user(u):
                if !model.input.contains(.image) {
                    u.content = u.content.map { if case .image = $0 { .text("[图片：当前模型不支持图片]") } else { $0 } }
                }
                out.append(.user(u))
            }
        }
        return out
    }
}
