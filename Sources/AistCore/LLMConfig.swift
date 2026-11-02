import Foundation

/// Which model endpoint to call. Any Anthropic-Messages-compatible endpoint works
/// (DeepSeek's /anthropic today, Claude later — only baseURL/model/key change).
public struct LLMConfig: Codable, Sendable {
    public var provider: String
    public var baseURL: URL
    public var model: String
    public var apiKey: String?
    /// Extended thinking. Off by default: to-do extraction doesn't need it, and on DeepSeek it costs ~5s per request.
    public var thinking: Bool?
    /// Wire protocol; nil (older config files) means Anthropic Messages.
    public var format: LLMFormat?

    public init(provider: String, baseURL: URL, model: String, apiKey: String?, thinking: Bool? = nil, format: LLMFormat? = nil) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.thinking = thinking
        self.format = format
    }

    public static let keychainService = "com.aist.llm-api-key"

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/aist/config.json")
    }

    public static let `default` = LLMConfig(
        provider: "deepseek",
        baseURL: URL(string: "https://api.deepseek.com/anthropic")!,
        model: "deepseek-flash",
        apiKey: nil
    )

    public enum ConfigError: LocalizedError {
        case missingKey(String)
        case missingModel(String)
        public var errorDescription: String? {
            switch self {
            case let .missingKey(name): "还没有填写 \(name) 的 API 密钥：打开 设置 › AI 填写"
            case let .missingModel(name): "还没有选择 \(name) 的模型：打开 设置 › AI 选择"
            }
        }
    }

    /// Settings from the config file; the key from $AIST_API_KEY, else the Keychain, else the file.
    /// (SSH sessions can't read the login keychain, hence the env override for the CLI.)
    public static func load() throws -> LLMConfig {
        var config = Self.default
        if let data = try? Data(contentsOf: fileURL),
           let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], raw["llm"] != nil,
           let active = LLMProviderStore.load().current {
            // Providers set up in Settings › AI.
            config = active.config
            config.thinking = raw["thinking"] as? Bool
            if let env = ProcessInfo.processInfo.environment["AIST_API_KEY"], !env.isEmpty { config.apiKey = env }
            guard let key = config.apiKey, !key.isEmpty else { throw ConfigError.missingKey(active.name) }
            guard !config.model.isEmpty else { throw ConfigError.missingModel(active.name) }
            return config
        }
        if let data = try? Data(contentsOf: fileURL) {
            config = try JSONDecoder().decode(LLMConfig.self, from: data)
        }
        if let env = ProcessInfo.processInfo.environment["AIST_API_KEY"], !env.isEmpty {
            config.apiKey = env
        } else if let stored = KeychainStore.read(service: keychainService), !stored.isEmpty {
            config.apiKey = stored
        }
        guard let key = config.apiKey, !key.isEmpty else { throw ConfigError.missingKey("DeepSeek") }
        return config
    }

    /// Moves a plaintext key from the config file into the Keychain, then strips it from the file.
    /// Only works from a GUI session (the login keychain is locked to SSH sessions).
    @discardableResult
    public static func migrateKeyToKeychain() -> Bool {
        // Edit the raw JSON so other settings in the file (e.g. mail OAuth client IDs) survive.
        guard let data = try? Data(contentsOf: fileURL),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = dict["apiKey"] as? String, !key.isEmpty,
              KeychainStore.write(key, service: keychainService)
        else { return false }
        dict.removeValue(forKey: "apiKey")
        guard let stripped = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return false }
        return (try? stripped.write(to: fileURL, options: .atomic)) != nil
    }
}
