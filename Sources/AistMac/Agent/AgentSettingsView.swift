import AistAgent
import AistCore
import SwiftUI

/// Settings › 问答.
struct AgentSettingsView: View {
    @AppStorage(AgentSettings.searchKey) private var search: SearchBackend = .auto
    @AppStorage(AgentSettings.reasoningKey) private var reasoning = false
    @State private var tavilyKey = AgentSettings.tavilyKey ?? ""
    @State private var models = AgentSettings.models
    @State private var providers = LLMProviderStore.load().providers.filter { !$0.needsKey || $0.apiKey != nil }
    @State private var newProvider = ""
    @State private var newModel = ""

    var body: some View {
        Form {
            Section {
                if models.isEmpty {
                    Text("还没有添加：用「AI」设置里的默认模型")
                        .foregroundStyle(.secondary)
                }
                ForEach(models, id: \.self) { ref in
                    HStack(spacing: 10) {
                        if let p = providers.first(where: { $0.id == ref.provider }) {
                            ProviderLogo(provider: p, size: 22)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ref.model)
                            Text(providers.first { $0.id == ref.provider }?.name ?? ref.provider)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            models.removeAll { $0 == ref }
                            AgentSettings.models = models
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("移除")
                    }
                }
                HStack(spacing: 8) {
                    Picker("供应商", selection: $newProvider) {
                        ForEach(providers) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("模型", text: $newModel, prompt: Text(suggestions.first ?? "模型名"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Menu {
                        ForEach(suggestions, id: \.self) { m in Button(m) { newModel = m } }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(suggestions.isEmpty)
                    Button("添加", action: add)
                        .disabled(newProvider.isEmpty || newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("对话可用的模型")
            } footer: {
                Text("在问答输入框左下角切换。只列出「AI」里填好了密钥的供应商。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(selection: $search) {
                    ForEach(SearchBackend.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("联网搜索")
                    Text(detail)
                }
                if search == .tavily || search == .auto {
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 4) {
                            SecureField("Tavily API 密钥", text: $tavilyKey, prompt: Text("可选"))
                                .labelsHidden()
                                .onChange(of: tavilyKey) { _, key in
                                    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if k.isEmpty { KeychainStore.delete(service: AgentSettings.tavilyService) }
                                    else { KeychainStore.write(k, service: AgentSettings.tavilyService) }
                                }
                            Link("获取密钥…", destination: URL(string: "https://app.tavily.com/home")!).font(.caption)
                        }
                    } label: {
                        Text("Tavily 密钥")
                        Text("只保存在钥匙串")
                    }
                }
            } footer: {
                Text("网页抓取：有 DeepSeek 密钥时用 DeepSeek Fetch API，否则由本机直接读取网页。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $reasoning) {
                    Text("深度思考")
                    Text("回答前先推理，更慢、更费 token；模型不支持时忽略")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            providers = LLMProviderStore.load().providers.filter { !$0.needsKey || $0.apiKey != nil }
            if newProvider.isEmpty { newProvider = LLMProviderStore.load().current?.id ?? providers.first?.id ?? "" }
        }
    }

    private var suggestions: [String] {
        guard let p = providers.first(where: { $0.id == newProvider }) else { return [] }
        var out = p.suggestedModels
        if !p.model.isEmpty, !out.contains(p.model) { out.insert(p.model, at: 0) }
        return out
    }

    private func add() {
        let m = newModel.trimmingCharacters(in: .whitespaces)
        guard !newProvider.isEmpty, !m.isEmpty else { return }
        let ref = AgentModelRef(provider: newProvider, model: m)
        if !models.contains(ref) { models.append(ref) }
        AgentSettings.models = models
        newModel = ""
    }

    private var detail: String {
        switch search {
        case .auto: "模型自带搜索优先（DeepSeek、Claude），否则依次用 DeepSeek 搜索 API、Tavily、DuckDuckGo"
        case .hosted: "由模型服务商在服务器上搜索；当前模型不支持时不联网"
        case .deepseek: "用 DeepSeek 的 API 密钥调用它的搜索接口，按次计费"
        case .tavily: "需要 Tavily 密钥，免费额度每月 1000 次"
        case .duckduckgo: "免费、无需密钥；访问频繁时可能被暂时拒绝"
        case .off: "只用模型已有的知识回答"
        }
    }
}
