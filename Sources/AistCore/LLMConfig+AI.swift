import AistAI
import Foundation

extension LLMConfig {
    /// The current Settings › AI choice as an `AistAI.Model`.
    public var aiModel: Model {
        Catalog.model(id: model, provider: provider,
                      api: Self.api(wire),
                      baseURL: baseURL)
    }

    public static func api(_ format: LLMFormat) -> Api {
        switch format {
        case .anthropic: .anthropicMessages
        case .openai: .openaiCompletions
        case .responses: .openaiResponses
        }
    }

    public var streamOptions: StreamOptions {
        StreamOptions(apiKey: apiKey, reasoning: thinking == true ? .medium : nil)
    }
}
