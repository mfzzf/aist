import Foundation

/// The wire protocol a provider speaks.
public enum LLMFormat: String, Codable, Sendable, CaseIterable {
    /// POST {baseURL}/v1/messages (Anthropic, and the /anthropic endpoints of DeepSeek, Kimi, GLM…)
    case anthropic
    /// POST {baseURL}/chat/completions (OpenAI and everything OpenAI-compatible)
    case openai
    /// POST {baseURL}/responses (OpenAI's Responses API; AstraFlow serves DeepSeek this way)
    case responses
}

/// One model service. Built-ins ship with the app (the user only adds a key);
/// custom ones are added in Settings › AI.
public struct LLMProvider: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var format: LLMFormat
    public var baseURL: String
    public var model: String
    public var custom: Bool
    /// Where to create an API key.
    public var keyURL: String?
    public var suggestedModels: [String]
    /// Local servers (Ollama) need no key.
    public var needsKey: Bool
    /// The OpenAI-style model list, when it isn't at {baseURL}/models (e.g. /anthropic endpoints).
    public var modelsURL: String?
    /// Regional endpoints to choose from (AstraFlow); picking one sets baseURL.
    public var regions: [LLMRegion]?

    public init(id: String, name: String, format: LLMFormat, baseURL: String, model: String,
                custom: Bool = false, keyURL: String? = nil, suggestedModels: [String] = [], needsKey: Bool = true,
                modelsURL: String? = nil, regions: [LLMRegion]? = nil) {
        self.modelsURL = modelsURL
        self.regions = regions
        self.id = id
        self.name = name
        self.format = format
        self.baseURL = baseURL
        self.model = model
        self.custom = custom
        self.keyURL = keyURL
        self.suggestedModels = suggestedModels
        self.needsKey = needsKey
    }

    public var apiKey: String? {
        if let stored = KeychainStore.read(service: LLMConfig.keychainService, account: id), !stored.isEmpty {
            return stored
        }
        // The single DeepSeek key from before providers existed.
        if id == "deepseek", let legacy = KeychainStore.read(service: LLMConfig.keychainService), !legacy.isEmpty {
            return legacy
        }
        return nil
    }

    /// False when the Keychain refused the write.
    @discardableResult
    public func setAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if id == "deepseek" { KeychainStore.delete(service: LLMConfig.keychainService) }
            return KeychainStore.delete(service: LLMConfig.keychainService, account: id)
        }
        return KeychainStore.write(trimmed, service: LLMConfig.keychainService, account: id)
    }

    public var config: LLMConfig {
        LLMConfig(provider: id, baseURL: URL(string: baseURL) ?? LLMConfig.default.baseURL,
                  model: model, apiKey: needsKey ? apiKey : "none", format: format)
    }
}

public extension LLMProvider {
    static let builtIns: [LLMProvider] = [
        LLMProvider(id: "deepseek", name: "DeepSeek", format: .anthropic,
                    baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash",
                    keyURL: "https://platform.deepseek.com/api_keys",
                    suggestedModels: ["deepseek-flash", "deepseek-v4-pro"],
                    modelsURL: "https://api.deepseek.com/models"),
        LLMProvider(id: "anthropic", name: "Claude", format: .anthropic,
                    baseURL: "https://api.anthropic.com", model: "claude-sonnet-5-5",
                    keyURL: "https://console.anthropic.com/settings/keys",
                    suggestedModels: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]),
        LLMProvider(id: "openai", name: "OpenAI", format: .openai,
                    baseURL: "https://api.openai.com/v1", model: "gpt-5-mini",
                    keyURL: "https://platform.openai.com/api-keys"),
        LLMProvider(id: "gemini", name: "Gemini", format: .openai,
                    baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.5-flash",
                    keyURL: "https://aistudio.google.com/apikey"),
        LLMProvider(id: "moonshot", name: "Kimi", format: .anthropic,
                    baseURL: "https://api.moonshot.cn/anthropic", model: "kimi-k2-turbo-preview",
                    keyURL: "https://platform.moonshot.cn/console/api-keys",
                    modelsURL: "https://api.moonshot.cn/v1/models"),
        LLMProvider(id: "zhipu", name: "智谱 GLM", format: .anthropic,
                    baseURL: "https://open.bigmodel.cn/api/anthropic", model: "glm-4.6",
                    keyURL: "https://open.bigmodel.cn/usercenter/apikeys",
                    modelsURL: "https://open.bigmodel.cn/api/paas/v4/models"),
        LLMProvider(id: "qwen", name: "通义千问", format: .openai,
                    baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus",
                    keyURL: "https://bailian.console.aliyun.com/?apiKey=1"),
        // UCloud's model hub (formerly UModelverse); the id stays so saved keys keep working.
        LLMProvider(id: "umodelverse", name: "AstraFlow", format: .openai,
                    baseURL: "https://api-sg.umodelverse.ai/v1", model: "",
                    keyURL: "https://astraflow.ucloud.cn/",
                    regions: [
                        LLMRegion(name: "乌兰察布", detail: "固定接入乌兰察布地域", baseURL: "https://api-cn-wlcb.modelverse.cn/v1"),
                        LLMRegion(name: "上海二", detail: "固定接入上海二地域", baseURL: "https://api-cn-sh2.modelverse.cn/v1"),
                        LLMRegion(name: "美国洛杉矶", detail: "海外用户推荐，数据不回国", baseURL: "https://api-us-ca.umodelverse.ai/v1"),
                        LLMRegion(name: "新加坡", detail: "东南亚用户推荐，访问更快", baseURL: "https://api-sg.umodelverse.ai/v1"),
                        LLMRegion(name: "法兰克福", detail: "欧洲用户推荐，访问更快", baseURL: "https://api-ge-fra.umodelverse.ai/v1"),
                    ]),
        LLMProvider(id: "openrouter", name: "OpenRouter", format: .openai,
                    baseURL: "https://openrouter.ai/api/v1", model: "",
                    keyURL: "https://openrouter.ai/keys"),
        LLMProvider(id: "ollama", name: "Ollama（本地）", format: .openai,
                    baseURL: "http://localhost:11434/v1", model: "", needsKey: false),
    ]
}

/// Persists providers in the "llm" section of ~/.config/aist/config.json:
/// `{"active": id, "providers": [...]}` — built-ins store only their edits, custom ones in full.
/// Keys never go in the file; they live in the Keychain (service com.aist.llm-api-key, account = provider id).
public enum LLMProviderStore {
    public struct State: Sendable, Equatable {
        public var active: String
        public var providers: [LLMProvider]

        public var current: LLMProvider? { providers.first { $0.id == active } ?? providers.first }
    }

    private struct Stored: Codable {
        var active: String
        var providers: [LLMProvider]
    }

    public static func load() -> State {
        let dict = rawConfig()
        var providers = LLMProvider.builtIns
        var active = "deepseek"

        if let section = dict["llm"],
           let data = try? JSONSerialization.data(withJSONObject: section),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            active = stored.active
            for p in stored.providers {
                if let i = providers.firstIndex(where: { $0.id == p.id }), !p.custom {
                    providers[i].baseURL = p.baseURL
                    providers[i].model = p.model
                } else if p.custom {
                    providers.append(p)
                }
            }
        } else if let model = dict["model"] as? String, let base = dict["baseURL"] as? String {
            // Pre-provider config: one DeepSeek-style endpoint at the top level.
            providers[0].model = model
            providers[0].baseURL = base
        }
        return State(active: active, providers: providers)
    }

    public static func save(_ state: State) {
        var dict = rawConfig()
        let builtIns = Dictionary(uniqueKeysWithValues: LLMProvider.builtIns.map { ($0.id, $0) })
        let stored = Stored(active: state.active, providers: state.providers.filter { p in
            guard let original = builtIns[p.id] else { return true }
            return p.baseURL != original.baseURL || p.model != original.model
        })
        guard let data = try? JSONEncoder().encode(stored),
              let section = try? JSONSerialization.jsonObject(with: data) else { return }
        dict["llm"] = section
        guard let out = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? FileManager.default.createDirectory(at: LLMConfig.fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? out.write(to: LLMConfig.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: LLMConfig.fileURL.path)
    }

    private static func rawConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: LLMConfig.fileURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return dict
    }

    /// The provider's live model list (GET …/models), newest first when the server reports dates
    /// (OpenAI `created`, Anthropic `created_at`), otherwise in the server's order.
    public static func fetchModels(_ provider: LLMProvider, key: String?) async throws -> [LLMModelInfo] {
        let bearer = provider.format != .anthropic || provider.modelsURL != nil
        let urlString = provider.modelsURL
            ?? provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (bearer ? "/models" : "/v1/models?limit=1000")
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if bearer {
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        } else {
            request.setValue(key ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMClient.ClientError.http(code, String(decoding: data, as: UTF8.self)) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
        let iso = ISO8601DateFormatter()
        let models = items.enumerated().compactMap { index, item -> (Int, LLMModelInfo)? in
            guard let id = (item["id"] as? String) ?? (item["name"] as? String) else { return nil }
            var created: Date?
            if let t = item["created"] as? Double, t > 0 { created = Date(timeIntervalSince1970: t) }
            if let t = item["created_at"] as? String {
                iso.formatOptions = t.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
                created = iso.date(from: t)
            }
            let name = (item["display_name"] as? String) ?? (item["name"] as? String).flatMap { $0 == id ? nil : $0 }
            return (index, LLMModelInfo(id: id, name: name, created: created))
        }
        return models.sorted { a, b in
            switch (a.1.created, b.1.created) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.0 < b.0
            }
        }.map(\.1)
    }
}

public struct LLMRegion: Codable, Sendable, Hashable {
    public var name: String
    public var detail: String
    public var baseURL: String

    public init(name: String, detail: String, baseURL: String) {
        self.name = name
        self.detail = detail
        self.baseURL = baseURL
    }
}

public struct LLMModelInfo: Sendable, Hashable, Identifiable {
    public var id: String
    /// Display name, when the server gives one (e.g. "DeepSeek-V4.1-Flash").
    public var name: String?
    public var created: Date?

    public init(id: String, name: String? = nil, created: Date? = nil) {
        self.id = id
        self.name = name
        self.created = created
    }
}
