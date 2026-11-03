import AistAI
import Foundation

extension LLMConfig {
    /// The current Settings › AI choice as an `AistAI.Model`.
    public var aiModel: Model {
        Catalog.model(id: model, provider: provider,
                      api: (format ?? .anthropic) == .openai ? .openaiCompletions : .anthropicMessages,
                      baseURL: baseURL)
    }

    public var streamOptions: StreamOptions {
        StreamOptions(apiKey: apiKey, reasoning: thinking == true ? .medium : nil)
    }
}
