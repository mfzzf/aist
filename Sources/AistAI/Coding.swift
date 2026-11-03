import Foundation

// Stable, readable JSON for storage: every enum carries a "type"/"role" tag.


extension UserContent: Codable {
    private enum K: String, CodingKey { case type, text, image }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "image": self = .image(try c.decode(ImageContent.self, forKey: .image))
        default: self = .text(try c.decode(String.self, forKey: .text))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .text(t): try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case let .image(i): try c.encode("image", forKey: .type); try c.encode(i, forKey: .image)
        }
    }
}

extension AssistantContent: Codable {
    private enum K: String, CodingKey { case type, text, thinking, signature, toolCall, hosted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "thinking":
            self = .thinking(try c.decode(String.self, forKey: .thinking), signature: try c.decodeIfPresent(String.self, forKey: .signature))
        case "toolCall": self = .toolCall(try c.decode(ToolCall.self, forKey: .toolCall))
        case "hosted": self = .hosted(try c.decode(HostedBlock.self, forKey: .hosted))
        default: self = .text(try c.decode(String.self, forKey: .text))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .text(t):
            try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case let .thinking(t, sig):
            try c.encode("thinking", forKey: .type); try c.encode(t, forKey: .thinking)
            try c.encodeIfPresent(sig, forKey: .signature)
        case let .toolCall(call):
            try c.encode("toolCall", forKey: .type); try c.encode(call, forKey: .toolCall)
        case let .hosted(b):
            try c.encode("hosted", forKey: .type); try c.encode(b, forKey: .hosted)
        }
    }
}


extension Message: Codable {
    private enum K: String, CodingKey { case role }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .role) {
        case "assistant": self = .assistant(try AssistantMessage(from: decoder))
        case "toolResult": self = .toolResult(try ToolResultMessage(from: decoder))
        default: self = .user(try UserMessage(from: decoder))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .user(m): try c.encode("user", forKey: .role); try m.encode(to: encoder)
        case let .assistant(m): try c.encode("assistant", forKey: .role); try m.encode(to: encoder)
        case let .toolResult(m): try c.encode("toolResult", forKey: .role); try m.encode(to: encoder)
        }
    }

    public var role: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        case .toolResult: "toolResult"
        }
    }
}
