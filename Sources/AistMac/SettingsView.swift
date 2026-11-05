import AistCore
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Settings window, macOS-style: a toolbar of panes (通用 / 连接 / AI), each a grouped Form.
enum SettingsWindow {
    @MainActor
    static func make(cloud: CloudSync, reminders: RemindersSync, calendar: CalendarCenter, notifier: EventNotifier, mailTodos: MailAutoTodo, github: GitHubCenter, wecom: WeComCenter) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        func pane<V: View>(_ title: String, _ symbol: String, _ view: V, width: CGFloat = 500) {
            let host = NSHostingController(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
            host.sizingOptions = .preferredContentSize
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        pane("通用", "gearshape", GeneralSettings(cloud: cloud))
        pane("通知", "bell.badge", NotifySettings(reminders: reminders, notifier: notifier, mailTodos: mailTodos))
        pane("会议", "waveform", MeetingSettingsView(calendar: calendar))
        pane("连接", "link", ConnectionSettings(github: github, wecom: wecom))
        pane("AI", "sparkles", AISettings(), width: 700)
        pane("问答", "text.bubble", AgentSettingsView())
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }

    /// The connect sheets live on the main window: close Settings so the user lands there.
    static func closeForSheet() {
        NSApp.keyWindow?.performClose(nil)
    }
}

// MARK: - 会议

private struct MeetingSettingsView: View {
    @ObservedObject var calendar: CalendarCenter
    @AppStorage(MeetingSettings.engineKey) private var engine = MeetingSettings.Engine.local.rawValue
    @AppStorage(MeetingSettings.languageKey) private var language = "auto"
    @AppStorage(MeetingSettings.translateToKey) private var translateTo = ""
    @AppStorage(MeetingSettings.liveNotesKey) private var liveNotes = true
    @AppStorage(MeetingSettings.showLiveWindowKey) private var showLiveWindow = true
    @AppStorage(MeetingSettings.shareLiveWindowKey) private var shareLiveWindow = false
    @AppStorage(MeetingSettings.endOnHangUpKey) private var endOnHangUp = true
    @AppStorage(MeetingSettings.silenceMinutesKey) private var silenceMinutes = 10
    @AppStorage(MeetingSettings.promptOnCallKey) private var promptOnCall = true

    var body: some View {
        Form {
            Section {
                Picker(selection: $engine) {
                    Text("本机（Apple）").tag(MeetingSettings.Engine.local.rawValue)
                    Text("AstraFlow Gemini").tag(MeetingSettings.Engine.astraFlow.rawValue)
                } label: {
                    Text("识别引擎")
                    Text(engine == MeetingSettings.Engine.astraFlow.rawValue
                         ? "声音发送到 AstraFlow 识别，用 设置 › AI 里的密钥和地域，按时长计费"
                         : "在本机识别，声音不出电脑")
                }
                Picker("识别语言", selection: $language) {
                    ForEach(LiveTranscript.languageChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("字幕翻译", selection: $translateTo) {
                    ForEach(LiveTranscript.translationChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle(isOn: $liveNotes) {
                    Text("会中速记")
                    Text("大约每 45 秒用新内容更新要点和双方的待办，会持续调用你配置的 AI 服务")
                }
            } header: {
                Text("实时转写")
            } footer: {
                if engine == MeetingSettings.Engine.astraFlow.rawValue {
                    Text("Gemini 自动识别说话的语言；字幕翻译也由 AstraFlow 实时完成。只上传有人说话的片段。").foregroundStyle(.secondary)
                } else if !LiveTranscript.isSupported {
                    Text("本机实时转写需要 macOS 26；当前系统会在会议结束后转写。").foregroundStyle(.secondary)
                } else {
                    Text("「自动识别」会在中文、英文、马来语等已下载的语言里自动切换。").foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("开始录音时打开实况窗口", isOn: $showLiveWindow)
                Toggle(isOn: $shareLiveWindow) {
                    Text("共享屏幕时让对方看到实况窗口")
                    Text("关闭时，屏幕共享、录屏和截图都拍不到它")
                }
            } header: {
                Text("会议实况窗口")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { calendar.promptsToRecord && calendar.authorized },
                    set: { on in
                        calendar.promptsToRecord = on
                        if on, !calendar.authorized { Task { await calendar.requestAccess() } }
                    }
                )) {
                    Text("日程里的会议开始时提示录音")
                    Text("开始前 1 分钟弹出提示")
                }
                Toggle(isOn: $promptOnCall) {
                    Text("会议软件开始通话时提示录音")
                    Text("腾讯会议、Zoom、飞书、Teams 等开始使用麦克风时")
                }
                Toggle(isOn: $endOnHangUp) {
                    Text("会议软件挂断时自动结束录音")
                    Text("挂断 30 秒后结束，期间可以点「继续录音」")
                }
                Picker("没人说话时结束录音", selection: $silenceMinutes) {
                    Text("5 分钟后").tag(5)
                    Text("10 分钟后").tag(10)
                    Text("30 分钟后").tag(30)
                    Text("从不").tag(0)
                }
            } header: {
                Text("开始与结束")
            } footer: {
                Text("结束前会倒数 60 秒，可以继续录音。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 通用

/// Version, automatic checks and a manual "check now" (releases come from GitHub).
private struct UpdateSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section("更新") {
            LabeledContent {
                HStack(spacing: 8) {
                    status
                    switch updater.state {
                    case let .available(release):
                        Button("安装 \(release.version)") { updater.install(release) }
                    case .checking, .downloading, .installing:
                        EmptyView()
                    default:
                        Button("检查更新") { Task { await updater.check(userInitiated: true) } }
                    }
                }
            } label: {
                Text("Aist \(updater.currentVersion)")
                if let last = updater.lastCheck {
                    Text("上次检查：\(last.formatted(.relative(presentation: .named)))")
                }
            }
            Toggle(isOn: $updater.autoCheck) {
                Text("自动检查更新")
                Text("有新版本时提示你，一键安装并重新打开；安装包会校验开发者签名")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .checking:
            ProgressView().controlSize(.small)
            Text("正在检查…").foregroundStyle(.secondary)
        case let .downloading(p):
            ProgressView(value: p).frame(width: 80)
            Text("正在下载…").foregroundStyle(.secondary)
        case .installing:
            ProgressView().controlSize(.small)
            Text("正在安装…").foregroundStyle(.secondary)
        case .upToDate:
            Text("已是最新").foregroundStyle(.secondary)
        case let .failed(text):
            Text(text).foregroundStyle(.red).lineLimit(1).help(text)
        default:
            EmptyView()
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var cloud: CloudSync
    @AppStorage(UserIdentity.namesKey) private var myNames = ""
    @State private var hotkey = HotkeyManager.shared.current
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var screenOK = ScreenCapturer.hasPermission

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HotkeyRecorder(hotkey: $hotkey) { new in
                        HotkeyManager.shared.current = new
                        return HotkeyManager.shared.register() ? nil : "\(new.display) 已被系统或其他应用占用，请换一个"
                    }
                } label: {
                    Text("截屏分析")
                    Text("框选屏幕区域提取待办")
                }
                LabeledContent {
                    TextField("你的名字", text: $myNames, prompt: Text("张三, Alex"))
                        .labelsHidden()
                        .frame(width: 180)
                } label: {
                    Text("你的名字")
                    Text("AI 据此认出别人在 @ 你")
                }
                Toggle("在程序坞中显示", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: AppDelegate.showInDockKey) },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: AppDelegate.showInDockKey)
                        AppDelegate.applyDockPolicy()
                    }
                ))
                Toggle("登录时打开 Aist", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                LabeledContent {
                    HStack(spacing: 8) {
                        if cloud.status == .syncing { ProgressView().controlSize(.small) }
                        Text(cloud.statusText).foregroundStyle(.secondary)
                        if cloud.isEnabled {
                            Button("立即同步") { cloud.sync() }
                                .disabled(cloud.status == .syncing)
                        }
                    }
                } label: {
                    Text("iCloud 同步")
                    Text("和 iPhone 上的 Aist 共用一份待办")
                }
            }

            UpdateSection()

            Section {
                LabeledContent {
                    if screenOK {
                        Label("已允许", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    } else {
                        Button("打开系统设置…") { ScreenCapturer.openPermissionSettings() }
                    }
                } label: {
                    Text("屏幕录制权限")
                    Text("截屏分析需要")
                }
                LabeledContent {
                    Button("打开…") {
                        NotificationCenter.default.post(name: Onboarding.showNotification, object: nil)
                    }
                } label: {
                    Text("新手引导")
                    Text("重新设置权限、AI 模型和自动化")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { screenOK = await ScreenCapturer.checkPermission() }
        }
        .task { screenOK = await ScreenCapturer.checkPermission() }
    }
}

// MARK: - 通知

/// Things Aist does on its own and tells you about: mail to-dos, Reminders, calendar alerts.
private struct NotifySettings: View {
    @ObservedObject var reminders: RemindersSync
    @ObservedObject var notifier: EventNotifier
    @ObservedObject var mailTodos: MailAutoTodo

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $mailTodos.enabled) {
                    Text("自动从新邮件里识别待办")
                    Text("新邮件到达时由 AI 读一遍，需要你做的事加入待办")
                }
                Toggle(isOn: Binding(
                    get: { reminders.isEnabled },
                    set: { on in
                        if on { Task { await reminders.enable() } } else { reminders.disable() }
                    }
                )) {
                    Text("同步到「提醒事项」")
                    Text(remindersNote)
                }
                if reminders.status == .denied {
                    LabeledContent("提醒事项权限被关闭了") {
                        Button("打开系统设置…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                        }
                    }
                }
            } header: {
                Text("待办")
            }

            Section {
                Toggle("有新日程时通知", isOn: $notifier.notifyNew)
                Picker("开始前提醒", selection: Binding(
                    get: { (notifier.remindBefore15 ? 1 : 0) + (notifier.remindBefore5 ? 2 : 0) },
                    set: { v in
                        notifier.remindBefore15 = v & 1 != 0
                        notifier.remindBefore5 = v & 2 != 0
                    }
                )) {
                    Text("15 分钟和 5 分钟前").tag(3)
                    Text("15 分钟前").tag(1)
                    Text("5 分钟前").tag(2)
                    Text("不提醒").tag(0)
                }
            } header: {
                Text("日程通知")
            } footer: {
                if notifier.denied {
                    HStack {
                        Text("通知被关闭了，打开后才会在右上角弹出提醒。").foregroundStyle(.secondary)
                        Spacer()
                        Button("打开系统设置…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                        }
                        .controlSize(.small)
                    }
                } else {
                    Text("包括企业微信和「日历」App 里的日程。").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var remindersNote: String {
        switch reminders.status {
        case let .on(list): "与「\(list)」列表双向同步，经 iCloud 到 iPhone 和 Apple Watch"
        case .denied: "没有权限"
        case let .failed(message): "同步出错：\(message)"
        case .off: "待办出现在 iPhone 的「提醒事项」里，两边勾掉都会同步"
        }
    }
}

// MARK: - 连接

private struct ConnectionSettings: View {
    @ObservedObject var github: GitHubCenter
    @ObservedObject var wecom: WeComCenter

    var body: some View {
        Form {
            Section {
                AccountRow(icon: BrandMark.github, tint: Color(white: 0.13), name: "GitHub",
                           detail: github.login ?? "通知、Review 请求和指派") {
                    if github.login != nil {
                        Button("断开") { github.disconnect() }
                    } else {
                        Button("连接…") {
                            github.connecting = true
                            SettingsWindow.closeForSheet()
                        }
                    }
                }
                if github.login != nil {
                    Toggle("「请我 Review」「指派给我」自动加入待办", isOn: Binding(
                        get: { github.autoTodos }, set: { github.autoTodos = $0 }))
                }
            }

            Section {
                AccountRow(icon: BrandMark.wecom, tint: BrandColor.wecom, name: "企业微信", detail: wecomDetail) {
                    switch wecom.status {
                    case .checking, .installing: ProgressView().controlSize(.small)
                    case .authorized:
                        Button("重新授权…") { connectWeCom() }
                    case .notInstalled, .unauthorized:
                        Button(wecom.status == .unauthorized ? "扫码连接…" : "安装并连接…") { connectWeCom() }
                    }
                }
            } footer: {
                Text("账户凭据只保存在这台 Mac 的钥匙串里。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var wecomDetail: String {
        switch wecom.status {
        case .authorized:
            let today = wecom.schedules.filter { Calendar.current.isDateInToday($0.start) }.count
            return today > 0 ? "已连接 · 今天 \(today) 个日程" : "已连接 · 日程和会议"
        case .checking: return "正在检查…"
        case .installing: return "正在安装 wecom-cli…"
        case .notInstalled, .unauthorized: return "日程、会议，开会时提醒录音"
        }
    }

    private func connectWeCom() {
        wecom.connecting = true
        SettingsWindow.closeForSheet()
    }
}

/// Logo tile + name + one-line status + trailing action, like Internet Accounts in System Settings.
private struct AccountRow<Action: View>: View {
    let icon: NSImage
    let tint: Color
    let name: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 30, height: 30)
                .overlay { BrandIcon(image: icon, size: 18).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            action
        }
        .padding(.vertical, 2)
    }
}

// MARK: - AI

@MainActor
final class ProvidersModel: ObservableObject {
    @Published var state = LLMProviderStore.load()
    @Published var selection: String?

    init() {
        // -aistShotProvider <id>: open 设置 › AI on that provider (for -aistShots).
        selection = UserDefaults.standard.string(forKey: "aistShotProvider") ?? state.active
    }

    var builtIns: [LLMProvider] { state.providers.filter { !$0.custom } }
    var customs: [LLMProvider] { state.providers.filter(\.custom) }

    func binding(_ id: String) -> Binding<LLMProvider>? {
        guard state.providers.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.state.providers.first { $0.id == id } ?? LLMProvider.builtIns[0] },
            set: { new in
                guard let i = self.state.providers.firstIndex(where: { $0.id == id }) else { return }
                self.state.providers[i] = new
                LLMProviderStore.save(self.state)
            }
        )
    }

    func activate(_ id: String) {
        state.active = id
        LLMProviderStore.save(state)
    }

    func addCustom() {
        let p = LLMProvider(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: "新供应商",
                            format: .openai, baseURL: "https://", model: "", custom: true)
        state.providers.append(p)
        LLMProviderStore.save(state)
        selection = p.id
    }

    func remove(_ id: String) {
        guard let p = state.providers.first(where: { $0.id == id }), p.custom else { return }
        p.setAPIKey("")
        state.providers.removeAll { $0.id == id }
        if state.active == id { state.active = "deepseek" }
        LLMProviderStore.save(state)
        selection = state.active
    }
}

private struct AISettings: View {
    @StateObject private var model = ProvidersModel()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    Section("内置") {
                        ForEach(model.builtIns) { ProviderRow(provider: $0, active: model.state.active == $0.id).tag($0.id) }
                    }
                    if !model.customs.isEmpty {
                        Section("自定义") {
                            ForEach(model.customs) { ProviderRow(provider: $0, active: model.state.active == $0.id).tag($0.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                Divider()
                HStack(spacing: 0) {
                    Button { model.addCustom() } label: { Image(systemName: "plus").frame(width: 26, height: 22) }
                        .help("新增供应商（OpenAI 或 Anthropic 兼容接口）")
                    Divider().frame(height: 14)
                    Button {
                        if let id = model.selection { model.remove(id) }
                    } label: { Image(systemName: "minus").frame(width: 26, height: 22) }
                        .disabled(!(model.selection.flatMap { id in model.customs.first { $0.id == id } } != nil))
                        .help("删除这个自定义供应商")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
            .frame(width: 210)
            .padding([.leading, .vertical], 20)
            Group {
                if let id = model.selection, let binding = model.binding(id) {
                    ProviderDetail(provider: binding, isActive: model.state.active == id,
                                   activate: { model.activate(id) }, remove: { model.remove(id) })
                        .id(id)
                } else {
                    ContentUnavailableView("选择一个供应商", systemImage: "sparkles")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 460)
    }
}

private struct ProviderRow: View {
    let provider: LLMProvider
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProviderLogo(provider: provider, size: 22)
            Text(provider.name).lineLimit(1)
            Spacer(minLength: 4)
            if active {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).help("正在使用")
            }
        }
    }
}

/// The provider's logo (lobehub icons, MIT, in Resources/Mac/ProviderIcons) on a white tile,
/// or a monogram for custom providers.
struct ProviderLogo: View {
    let provider: LLMProvider
    var size: CGFloat

    private static var cache: [String: (NSImage, Bool)?] = [:]

    /// (image, isMonochrome) — mono icons use currentColor and are drawn as templates.
    private static func logo(_ id: String) -> (NSImage, Bool)? {
        if let hit = cache[id] { return hit }
        var result: (NSImage, Bool)?
        if let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "ProviderIcons"),
           let image = NSImage(contentsOf: url) {
            result = (image, false)
        } else if let url = Bundle.main.url(forResource: id, withExtension: "svg", subdirectory: "ProviderIcons"),
           let data = try? Data(contentsOf: url) {
            let text = String(decoding: data, as: UTF8.self)
            let mono = text.contains("currentColor")
            let fixed = mono ? text.replacingOccurrences(of: "currentColor", with: "black") : text
            if let image = NSImage(data: Data(fixed.utf8)) {
                image.isTemplate = mono
                result = (image, mono)
            }
        }
        cache[id] = result
        return result
    }

    var body: some View {
        if let (image, mono) = Self.logo(provider.id) {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(.white)
                .frame(width: size, height: size)
                .overlay {
                    Image(nsImage: image)
                        .renderingMode(mono ? .template : .original)
                        .resizable().scaledToFit()
                        .foregroundStyle(.black)
                        .padding(size * 0.18)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(.black.opacity(0.1), lineWidth: 0.5)
                }
        } else {
            ProviderMonogram(name: provider.name, size: size)
        }
    }
}

/// First letter on a tinted rounded square — providers have no logos of their own here.
private struct ProviderMonogram: View {
    let name: String
    var size: CGFloat

    private var tint: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan, .brown, .mint]
        return palette[abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % palette.count]
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}

struct ProviderDetail: View {
    @Binding var provider: LLMProvider
    let isActive: Bool
    let activate: () -> Void
    let remove: () -> Void

    static func protocolName(_ p: LLMProvider) -> String {
        let wire = p.format == .openai && LLMConfig.prefersResponses(host: URL(string: p.baseURL)?.host, model: p.model)
            ? .responses : p.format
        return switch wire {
        case .anthropic: "Anthropic Messages 接口"
        case .responses: "OpenAI Responses 接口"
        case .openai:
            p.id == "umodelverse" ? "OpenAI 兼容接口 · DeepSeek 走 Responses 接口" : "OpenAI 兼容接口"
        }
    }

    @State private var key = ""
    @State private var models: [LLMModelInfo] = []
    @State private var loadingModels = false
    @State private var test: TestState = .idle
    @State private var pickingModel = false
    @AppStorage(MeetingSettings.engineKey) private var meetingEngine = MeetingSettings.Engine.local.rawValue

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ProviderLogo(provider: provider, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name).font(.headline)
                        Text(Self.protocolName(provider))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isActive {
                        Label("正在使用", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Button("设为默认", action: activate)
                            .disabled(provider.model.isEmpty || (provider.needsKey && key.isEmpty))
                    }
                }
            }

            Section {
                if provider.custom {
                    TextField("名称", text: $provider.name)
                    Picker("接口格式", selection: $provider.format) {
                        Text("OpenAI 兼容").tag(LLMFormat.openai)
                        Text("OpenAI Responses").tag(LLMFormat.responses)
                        Text("Anthropic Messages").tag(LLMFormat.anthropic)
                    }
                }
                if let regions = provider.regions, !regions.isEmpty {
                    Picker(selection: $provider.baseURL) {
                        ForEach(regions, id: \.baseURL) { r in
                            Text(r.name).tag(r.baseURL)
                        }
                        if !regions.contains(where: { $0.baseURL == provider.baseURL }) {
                            Text("自定义").tag(provider.baseURL)
                        }
                    } label: {
                        Text("地域")
                        Text(regions.first { $0.baseURL == provider.baseURL }.map { "\($0.detail) · \(URL(string: $0.baseURL)?.host ?? "")" } ?? provider.baseURL)
                    }
                }
                // Region-based providers (AstraFlow) are fully set up: region, key, model.
                if provider.regions == nil {
                    TextField("接口地址", text: $provider.baseURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                }
                if provider.needsKey {
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 4) {
                            SecureField("API 密钥", text: $key, prompt: Text("粘贴 API 密钥"))
                                .labelsHidden()
                                .onSubmit { provider.setAPIKey(key) }
                                .onChange(of: key) { _, new in provider.setAPIKey(new) }
                            if let url = provider.keyURL.flatMap(URL.init(string:)) {
                                Link("获取密钥…", destination: url).font(.caption)
                            }
                        }
                    } label: {
                        Text("API 密钥")
                        Text("只保存在钥匙串")
                    }
                }
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("模型", text: $provider.model, prompt: Text("例如 \(provider.suggestedModels.first ?? "model-name")"))
                            .labelsHidden()
                            .autocorrectionDisabled()
                        Button {
                            pickingModel.toggle()
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                        .buttonStyle(.borderless)
                        .help("选择模型")
                        .popover(isPresented: $pickingModel, arrowEdge: .bottom) {
                            ModelPicker(selection: $provider.model,
                                        models: models.isEmpty
                                            ? provider.suggestedModels.map { LLMModelInfo(id: $0) }
                                            : models,
                                        note: models.isEmpty
                                            ? (loadingModels ? "正在获取模型列表…" : "推荐模型 · 点 ↻ 获取最新列表")
                                            : nil,
                                        isPresented: $pickingModel)
                        }
                        Button {
                            Task { await loadModels() }
                        } label: {
                            if loadingModels { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                        }
                        .buttonStyle(.borderless)
                        .help("从 /models 接口获取最新模型列表")
                    }
                } label: {
                    Text("模型")
                    if let info = models.first(where: { $0.id == provider.model }) {
                        Text([info.name, info.created.map { "发布于 " + Self.day($0) }].compactMap { $0 }.joined(separator: " · "))
                    } else if !models.isEmpty {
                        Text("最新：\(models[0].id)")
                    }
                }
            }

            if provider.id == "umodelverse" {
                Section {
                    Toggle(isOn: Binding(
                        get: { meetingEngine == MeetingSettings.Engine.astraFlow.rawValue },
                        set: { meetingEngine = ($0 ? MeetingSettings.Engine.astraFlow : .local).rawValue }
                    )) {
                        Text("用于会议实时转写")
                        Text("转写：\(CloudEndpoint.transcribeModel)\n字幕翻译：\(CloudEndpoint.translateModel)")
                    }
                } header: {
                    Text("会议")
                } footer: {
                    Text(meetingEngine == MeetingSettings.Engine.astraFlow.rawValue
                         ? "会议录音时，有人说话的片段发送到 AstraFlow 识别，用这里的密钥，按时长计费。识别语言和字幕翻译在 设置 › 会议。"
                         : "关闭时在本机识别，声音不出电脑。")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("测试连接") { Task { await runTest() } }
                        .disabled(test == .running || provider.model.isEmpty)
                    switch test {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case let .ok(ms):
                        Label("连接成功 · \(ms)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case let .failed(msg):
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).lineLimit(2).help(msg)
                    }
                    Spacer()
                    if provider.custom {
                        Button("删除", role: .destructive, action: remove)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { key = provider.apiKey ?? "" }
        .task {
            if !provider.needsKey || !key.isEmpty { await loadModels(quiet: true) }
            // -aistShotPicker <query>: open the model list with that search (for screenshots).
            if let q = UserDefaults.standard.string(forKey: "aistShotPicker") {
                ModelPicker.initialQuery = q
                if models.isEmpty { await loadModels(quiet: true) }
                try? await Task.sleep(for: .seconds(0.5))
                pickingModel = true
            }
        }
    }

    private func loadModels(quiet: Bool = false) async {
        loadingModels = true
        defer { loadingModels = false }
        do {
            models = try await LLMProviderStore.fetchModels(provider, key: key)
            if !quiet { test = models.isEmpty ? .failed("接口没有返回模型列表") : .idle }
        } catch {
            if !quiet { test = .failed(Self.short(error)) }
        }
    }

    static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    private func runTest() async {
        test = .running
        var config = provider.config
        config.apiKey = provider.needsKey ? key : "none"
        let started = Date()
        do {
            _ = try await LLMClient(config: config).complete(system: "Reply with OK.", parts: [.text("ping")], maxTokens: 16)
            test = .ok("\(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            test = .failed(Self.short(error))
        }
    }

    static func short(_ error: Error) -> String {
        let text = error.localizedDescription
        // Pull "message" out of a JSON error body when there is one.
        if let start = text.firstIndex(of: "{"),
           let json = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any] {
            let err = json["error"] as? [String: Any]
            if let msg = (err?["message"] as? String) ?? (json["message"] as? String) {
                return String(text[..<start]) + msg
            }
        }
        return String(text.prefix(160))
    }
}

/// The model list in a popover: type to filter, Return picks the first match, click picks any.
private struct ModelPicker: View {
    @Binding var selection: String
    let models: [LLMModelInfo]
    let note: String?
    @Binding var isPresented: Bool
    @State private var query = ModelPicker.initialQuery
    @FocusState private var searchFocused: Bool
    static var initialQuery = ""

    private var filtered: [LLMModelInfo] {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return models }
        return models.filter { m in
            let text = (m.id + " " + (m.name ?? "")).lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索模型", text: $query, prompt: Text("搜索 \(models.count) 个模型"))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = filtered.first { pick(first.id) } }
                .padding(10)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider()
            let rows = filtered
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text("没有匹配的模型").foregroundStyle(.secondary)
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("使用「\(query.trimmingCharacters(in: .whitespaces))」") {
                            pick(query.trimmingCharacters(in: .whitespaces))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { m in
                    Button { pick(m.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.id)
                                let extra = [m.name, m.created.map(ProviderDetail.day)].compactMap { $0 }
                                if !extra.isEmpty {
                                    Text(extra.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if m.id == selection {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(width: 360, height: 420)
        .onAppear { searchFocused = true }
    }

    private func pick(_ id: String) {
        selection = id
        isPresented = false
    }
}

/// Click, then press the new combination — held modifiers show live, Esc cancels.
/// The global hotkey is suspended while recording; if the new one can't be registered, the old one comes back.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    /// Returns an error to show, or nil when the new hotkey is live.
    var onChange: (Hotkey) -> String?
    @State private var recording = false
    @State private var live: NSEvent.ModifierFlags = []
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { recording ? stop() : start() } label: {
                Text(label)
                    .monospaced()
                    .foregroundStyle(recording && live.isEmpty ? .secondary : .primary)
                    .frame(minWidth: 110)
            }
            .tint(recording ? .accentColor : nil)
            .buttonStyle(.bordered)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private var label: String {
        guard recording else { return hotkey.display }
        if live.isEmpty { return "按下快捷键…" }
        return Hotkey.symbols(live) + "…"
    }

    private func start() {
        problem = nil
        live = []
        recording = true
        HotkeyManager.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                live = event.modifierFlags.intersection([.command, .option, .control, .shift])
                return event
            }
            if Int(event.keyCode) == kVK_Escape, live.isEmpty {
                stop()
                return nil
            }
            guard let new = Hotkey(event: event) else {
                problem = "需要配合 ⌘、⌥ 或 ⌃ 键（F1–F12 除外）"
                NSSound.beep()
                return nil
            }
            if let reason = new.rejectionReason {
                problem = reason
                NSSound.beep()
                return nil
            }
            let old = hotkey
            hotkey = new
            if let error = onChange(new) {
                problem = error
                hotkey = old
                _ = onChange(old)
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        live = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotkeyManager.shared.register()
    }
}
