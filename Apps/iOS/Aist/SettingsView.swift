import AistCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloud: CloudSync
    @State private var state = LLMProviderStore.load()
    @State private var key = ""
    @State private var models: [LLMModelInfo] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    @AppStorage(Profile.namesKey) private var names = ""
    @AppStorage(Profile.backgroundKey) private var background = ""
    @AppStorage(SpeechRecorder.localeKey) private var voiceLocale = SpeechRecorder.defaultLocale

    private var provider: LLMProvider? { state.current }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("服务商", selection: activeBinding) {
                        ForEach(state.providers) { p in Text(p.name).tag(p.id) }
                    }
                    if let provider {
                        if let regions = provider.regions, !regions.isEmpty {
                            Picker("地域", selection: providerBinding(\.baseURL)) {
                                ForEach(regions, id: \.baseURL) { r in Text(r.name).tag(r.baseURL) }
                            }
                        }
                        if provider.needsKey {
                            SecureField("API Key", text: $key)
                                .textContentType(.password)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onChange(of: key) { provider.setAPIKey($0) }
                        }
                        modelRow(provider)
                    }
                } header: {
                    Text("AI")
                } footer: {
                    if let url = provider?.keyURL.flatMap(URL.init(string:)) {
                        Link("去 \(provider?.name ?? "") 获取 API Key", destination: url)
                    }
                }

                Section {
                    TextField("张三, Alex", text: $names)
                        .autocorrectionDisabled()
                } header: {
                    Text("你的名字")
                } footer: {
                    Text("中文名、英文名、常用称呼，用逗号分开。别人提到这些名字时，AI 知道说的是你。")
                }

                Section {
                    TextField("我负责 Nimbus 客户端和模型接入；老板：Kevin；主要客户：Acme", text: $background, axis: .vertical)
                        .lineLimit(2 ... 6)
                } header: {
                    Text("工作背景")
                } footer: {
                    Text("你负责的产品、项目、客户、老板。这些事没人点名时，AI 也会主动记给你；写「不归我管」的类别会跳过。")
                }

                Section {
                    LabeledContent("iCloud 同步") {
                        HStack(spacing: 6) {
                            if cloud.status == .syncing { ProgressView().controlSize(.small) }
                            Text(cloud.statusText).foregroundStyle(.secondary)
                        }
                    }
                    if cloud.isEnabled {
                        Button("立即同步") { cloud.sync() }
                            .disabled(cloud.status == .syncing)
                    }
                } footer: {
                    Text("待办在登录同一 Apple 账号的 iPhone 和 Mac 之间自动同步，存在你自己的 iCloud 里。")
                }

                Section("语音") {
                    Picker("识别语言", selection: $voiceLocale) {
                        ForEach(SpeechRecorder.languages, id: \.id) { l in Text(l.name).tag(l.id) }
                    }
                }

                Section {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .onAppear { key = provider?.apiKey ?? "" }
        }
    }

    @ViewBuilder
    private func modelRow(_ provider: LLMProvider) -> some View {
        let options = models.map(\.id) + (provider.suggestedModels.filter { s in !models.contains { $0.id == s } })
        HStack {
            TextField("模型", text: providerBinding(\.model))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if loadingModels {
                ProgressView()
            } else {
                Menu {
                    Button("从服务商获取列表") { Task { await loadModels(provider) } }
                    if !options.isEmpty {
                        Divider()
                        ForEach(options, id: \.self) { id in
                            Button(id) { update { $0.model = id } }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
            }
        }
        if let modelError {
            Text(modelError).font(.caption).foregroundStyle(.red)
        }
    }

    private var activeBinding: Binding<String> {
        Binding(get: { state.active }, set: { id in
            state.active = id
            LLMProviderStore.save(state)
            key = state.current?.apiKey ?? ""
            models = []
            modelError = nil
        })
    }

    private func providerBinding(_ path: WritableKeyPath<LLMProvider, String>) -> Binding<String> {
        Binding(get: { provider?[keyPath: path] ?? "" }, set: { value in update { $0[keyPath: path] = value } })
    }

    private func update(_ change: (inout LLMProvider) -> Void) {
        guard let i = state.providers.firstIndex(where: { $0.id == state.active }) else { return }
        change(&state.providers[i])
        LLMProviderStore.save(state)
    }

    private func loadModels(_ provider: LLMProvider) async {
        loadingModels = true
        modelError = nil
        defer { loadingModels = false }
        do {
            models = try await LLMProviderStore.fetchModels(provider, key: key)
            if provider.model.isEmpty, let first = models.first { update { $0.model = first.id } }
        } catch {
            modelError = error.localizedDescription
        }
    }
}
