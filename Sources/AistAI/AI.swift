import Foundation

public typealias StreamFunction = @Sendable (Model, Context, StreamOptions) -> AssistantEventStream

/// Wire protocol → implementation. Built-ins are registered on first use; register more (or
/// replace one, e.g. with a fixture player in tests) at any time.
public enum ApiRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [Api: StreamFunction] = [
        .anthropicMessages: { AnthropicMessages.stream($0, $1, $2) },
        .openaiCompletions: { OpenAICompletions.stream($0, $1, $2) },
    ]

    public static func register(_ api: Api, _ fn: @escaping StreamFunction) {
        lock.withLock { table[api] = fn }
    }

    public static func stream(for api: Api) -> StreamFunction? {
        lock.withLock { table[api] }
    }
}

/// The one entry point: `AI.stream(model, context, options)`.
public enum AI {
    public static func stream(_ model: Model, _ context: Context, _ options: StreamOptions = StreamOptions()) -> AssistantEventStream {
        guard let fn = ApiRegistry.stream(for: model.api) else {
            return AsyncStream { c in
                var m = AssistantMessage(for: model)
                m.stopReason = .error
                m.errorMessage = "不支持的接口协议：\(model.api.rawValue)"
                c.yield(.error(reason: .error, message: m))
                c.finish()
            }
        }
        var ctx = context
        ctx.messages = Transform.prepare(context.messages, for: model)
        return fn(model, ctx, options)
    }

    /// Non-streaming convenience; errors come back as `stopReason == .error` with `errorMessage`.
    public static func complete(_ model: Model, _ context: Context, _ options: StreamOptions = StreamOptions()) async -> AssistantMessage {
        await stream(model, context, options).result() ?? {
            var m = AssistantMessage(for: model)
            m.stopReason = .aborted
            return m
        }()
    }
}
