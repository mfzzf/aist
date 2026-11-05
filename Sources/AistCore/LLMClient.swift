import Foundation

/// Calls an Anthropic-Messages-compatible endpoint and returns the concatenated text blocks.
public struct LLMClient: Sendable {
    public enum Part: Sendable {
        case text(String)
        case image(Data, mediaType: String)
    }

    public enum ClientError: LocalizedError {
        case http(Int, String)
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case let .http(code, body): "AI 接口返回错误 \(code)：\(body.prefix(200))"
            case .emptyResponse: "AI 没有返回内容"
            }
        }
    }

    public let config: LLMConfig

    public init(config: LLMConfig) { self.config = config }

    /// Anthropic's own API: newer Claude models reject `thinking: disabled` and forced `tool_choice`.
    private var isAnthropicFirstParty: Bool { config.baseURL.host?.hasSuffix("anthropic.com") == true }

    // MARK: - Structured output via a tool call

    /// A JSON-Schema tool the model fills in, instead of free-form JSON in text.
    public struct Tool: Sendable {
        public var name: String
        public var description: String
        /// JSON Schema of the tool input, as JSON text.
        public var schema: String

        public init(name: String, description: String, schema: String) {
            self.name = name
            self.description = description
            self.schema = schema
        }

        var schemaObject: Any { (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) ?? [:] }
    }

    /// The tool's arguments (JSON), or text when the provider answered without calling it.
    public enum ToolResult: Sendable {
        case arguments(Data)
        case text(String)
    }

    /// Asks the model to answer by calling `tool`. Providers differ in what they accept, so it steps down:
    /// forced tool call (+ strict schema on Anthropic) → tool offered with "auto" → plain text,
    /// moving on only when the provider rejects the request (HTTP 400/422).
    public func callTool(system: String, parts: [Part], tool: Tool, maxTokens: Int = 4000) async throws -> ToolResult {
        var lastError: Error?
        for mode in [ToolMode.forced, .auto, .none] {
            if mode == .forced, isAnthropicFirstParty { continue } // 400 on current Claude models
            do {
                switch config.wire {
                case .anthropic: return try await anthropicTool(system: system, parts: parts, tool: tool, mode: mode, maxTokens: maxTokens)
                case .openai: return try await openAITool(system: system, parts: parts, tool: tool, mode: mode, maxTokens: maxTokens)
                case .responses: return try await responsesTool(system: system, parts: parts, tool: tool, mode: mode, maxTokens: maxTokens)
                }
            } catch let ClientError.http(code, body) where code == 400 || code == 422 {
                lastError = ClientError.http(code, body)
            }
        }
        throw lastError ?? ClientError.emptyResponse
    }

    private enum ToolMode { case forced, auto, none }

    private func anthropicContent(_ parts: [Part]) -> [[String: Any]] {
        parts.map {
            switch $0 {
            case let .text(text):
                return ["type": "text", "text": text]
            case let .image(data, mediaType):
                return ["type": "image", "source": [
                    "type": "base64", "media_type": mediaType, "data": data.base64EncodedString(),
                ]]
            }
        }
    }

    private func anthropicTool(system: String, parts: [Part], tool: Tool, mode: ToolMode, maxTokens: Int) async throws -> ToolResult {
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": anthropicContent(parts)]],
        ]
        if config.thinking != true, !isAnthropicFirstParty { body["thinking"] = ["type": "disabled"] }
        if mode != .none {
            var def: [String: Any] = ["name": tool.name, "description": tool.description, "input_schema": tool.schemaObject]
            if isAnthropicFirstParty { def["strict"] = true }
            body["tools"] = [def]
            body["tool_choice"] = mode == .forced ? ["type": "tool", "name": tool.name] : ["type": "auto"]
        }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(config.apiKey ?? "", forHTTPHeaderField: "x-api-key")
        let json = try await send(&request, body: body)
        let blocks = json["content"] as? [[String: Any]] ?? []
        if let use = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == tool.name }),
           let input = use["input"], let data = try? JSONSerialization.data(withJSONObject: input) {
            return .arguments(data)
        }
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return .text(text)
    }

    private func openAITool(system: String, parts: [Part], tool: Tool, mode: ToolMode, maxTokens: Int) async throws -> ToolResult {
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": openAIContent(parts)],
            ],
        ]
        if mode != .none {
            body["tools"] = [["type": "function", "function": [
                "name": tool.name, "description": tool.description, "parameters": tool.schemaObject,
            ]]]
            body["tool_choice"] = mode == .forced ? ["type": "function", "function": ["name": tool.name]] : "auto"
        }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let json = try await send(&request, body: body)
        let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        if let calls = message?["tool_calls"] as? [[String: Any]],
           let fn = calls.compactMap({ $0["function"] as? [String: Any] }).first(where: { $0["name"] as? String == tool.name }),
           let args = fn["arguments"] as? String {
            return .arguments(Data(args.utf8))
        }
        let text: String = if let s = message?["content"] as? String {
            s
        } else {
            (message?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return .text(text)
    }

    private func openAIContent(_ parts: [Part]) -> [[String: Any]] {
        parts.map {
            switch $0 {
            case let .text(text):
                return ["type": "text", "text": text]
            case let .image(data, mediaType):
                return ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(data.base64EncodedString())"]]
            }
        }
    }

    // MARK: - Plain text

    public func complete(system: String, parts: [Part], maxTokens: Int = 4000) async throws -> String {
        switch config.wire {
        case .anthropic: try await anthropic(system: system, parts: parts, maxTokens: maxTokens)
        case .openai: try await openAI(system: system, parts: parts, maxTokens: maxTokens)
        case .responses: try responsesText(try await responses(system: system, parts: parts, tool: nil, mode: .none, maxTokens: maxTokens))
        }
    }

    private func anthropic(system: String, parts: [Part], maxTokens: Int) async throws -> String {
        let content: [[String: Any]] = parts.map {
            switch $0 {
            case let .text(text):
                return ["type": "text", "text": text]
            case let .image(data, mediaType):
                return ["type": "image", "source": [
                    "type": "base64", "media_type": mediaType, "data": data.base64EncodedString(),
                ]]
            }
        }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
        ]
        if config.thinking != true, !isAnthropicFirstParty {
            body["thinking"] = ["type": "disabled"]
        }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(config.apiKey ?? "", forHTTPHeaderField: "x-api-key")
        let json = try await send(&request, body: body)
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return text
    }

    private func openAI(system: String, parts: [Part], maxTokens: Int) async throws -> String {
        let content: [[String: Any]] = parts.map {
            switch $0 {
            case let .text(text):
                return ["type": "text", "text": text]
            case let .image(data, mediaType):
                return ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(data.base64EncodedString())"]]
            }
        }
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content],
            ],
        ]
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let json = try await send(&request, body: body)
        let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        let text: String = if let s = message?["content"] as? String {
            s
        } else {
            (message?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return text
    }

    // MARK: - Responses API

    private func responsesTool(system: String, parts: [Part], tool: Tool, mode: ToolMode, maxTokens: Int) async throws -> ToolResult {
        let json = try await responses(system: system, parts: parts, tool: tool, mode: mode, maxTokens: maxTokens)
        let output = json["output"] as? [[String: Any]] ?? []
        if let call = output.first(where: { $0["type"] as? String == "function_call" && $0["name"] as? String == tool.name }),
           let args = call["arguments"] as? String {
            return .arguments(Data(args.utf8))
        }
        return .text(try responsesText(json))
    }

    private func responses(system: String, parts: [Part], tool: Tool?, mode: ToolMode, maxTokens: Int) async throws -> [String: Any] {
        let content: [[String: Any]] = parts.map {
            switch $0 {
            case let .text(text):
                return ["type": "input_text", "text": text]
            case let .image(data, mediaType):
                return ["type": "input_image", "image_url": "data:\(mediaType);base64,\(data.base64EncodedString())"]
            }
        }
        var body: [String: Any] = [
            "model": config.model,
            "max_output_tokens": maxTokens,
            "store": false,
            "instructions": system,
            "input": [["role": "user", "content": content]],
        ]
        // DeepSeek on AstraFlow thinks unless told not to (≈5 s per request).
        if config.thinking != true, config.model.lowercased().contains("deepseek") { body["reasoning"] = ["effort": "none"] }
        if let tool, mode != .none {
            body["tools"] = [["type": "function", "name": tool.name, "description": tool.description,
                              "parameters": tool.schemaObject]]
            body["tool_choice"] = mode == .forced ? ["type": "function", "name": tool.name] : "auto"
        }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("responses"))
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return try await send(&request, body: body)
    }

    private func responsesText(_ json: [String: Any]) throws -> String {
        let output = json["output"] as? [[String: Any]] ?? []
        let text = output.filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return text
    }

    private func send(_ request: inout URLRequest, body: [String: Any]) async throws -> [String: Any] {
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ClientError.http(code, String(decoding: data, as: UTF8.self))
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
