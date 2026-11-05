import AistCore
import AppKit
import AVFoundation
import EventKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// First-launch setup: permissions, an AI provider, and which automations to switch on.
/// Reopen from 帮助 › 新手引导.
enum Onboarding {
    static let doneKey = "onboarding.done"
    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }
    /// Posted by the 新手引导 buttons (Settings, menu); AppDelegate opens the window.
    static let showNotification = Notification.Name("aist.showOnboarding")

    @MainActor
    static func makeWindow(_ view: OnboardingView) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "欢迎使用 Aist"
        return window
    }
}

struct OnboardingView: View {
    @ObservedObject var calendar: CalendarCenter
    @ObservedObject var reminders: RemindersSync
    @ObservedObject var notifier: EventNotifier
    @ObservedObject var mailTodos: MailAutoTodo
    @ObservedObject var github: GitHubCenter
    @ObservedObject var wecom: WeComCenter
    var finish: () -> Void
    var addMailAccount: () -> Void
    var initialStep = 0

    @State private var step = 0
    @AppStorage(UserIdentity.namesKey) private var myNames = ""
    @ObservedObject private var updater = Updater.shared
    private let steps = ["欢迎", "权限", "AI 模型", "自动化", "会议"]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: PermissionsStep(calendar: calendar, notifier: notifier, reminderSync: reminders)
                case 2: ModelStep()
                case 3: automationStep
                default: MeetingStep(calendar: calendar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity))

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: step)
                Spacer()
                if step > 0 {
                    Button("上一步") { withAnimation(.snappy) { step -= 1 } }
                        .keyboardShortcut(.cancelAction)
                }
                Button(step == steps.count - 1 ? "开始使用" : "继续") {
                    if step == steps.count - 1 { finish() } else { withAnimation(.snappy) { step += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 560)
        .onAppear { step = initialStep }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 128, height: 128)
            Text("欢迎使用 Aist").font(.largeTitle.weight(.bold))
            Text("你的 AI 助理：截屏、邮件、会议里的事，自动整理成待办。")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "text.viewfinder", tint: .blue, title: "截屏识别待办",
                        detail: "按 \(HotkeyManager.shared.current.display) 框选屏幕，聊天记录、文档里的事一键收进待办")
                Feature(symbol: "envelope.badge", tint: .orange, title: "邮件自动分析",
                        detail: "新邮件到达时读出需要你做的事和截止时间")
                Feature(symbol: "waveform", tint: .red, title: "会议录音与纪要",
                        detail: "日程开始前提醒录音，结束后生成纪要和行动项")
                Feature(symbol: "calendar", tint: .green, title: "日程与提醒事项",
                        detail: "企业微信、日历、GitHub 通知汇到一处，经 iCloud 同步到 iPhone")
            }
            .padding(.top, 8)
        }
        .padding(40)
    }

    private var automationStep: some View {
        Form {
            Section {
                LabeledContent {
                    TextField("你的名字", text: $myNames, prompt: Text("张三, Alex"))
                        .labelsHidden()
                        .frame(width: 200)
                } label: {
                    Text("你的名字")
                    Text("中英文名、昵称，逗号分隔。AI 据此认出别人在 @ 你、交代给你的事")
                }
                Toggle(isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                )) {
                    Text("登录时打开 Aist")
                    Text("开机后自动在菜单栏待命，快捷键和提醒随时可用")
                }
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: AppDelegate.showInDockKey) },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: AppDelegate.showInDockKey)
                        AppDelegate.applyDockPolicy()
                    }
                )) {
                    Text("在程序坞中显示")
                    Text("关闭后只在菜单栏显示")
                }
                Toggle(isOn: $updater.autoCheck) {
                    Text("自动检查更新")
                    Text("有新版本时提示你一键安装")
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("自动化").font(.title2.weight(.bold)).foregroundStyle(.primary)
                    Text("选择 Aist 在后台帮你做哪些事，之后都可以在设置里更改。")
                        .font(.body).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                .textCase(nil)
            }

            Section {
                Toggle(isOn: $mailTodos.enabled) {
                    Text("自动从新邮件里识别待办")
                    Text("新邮件到达时交给 AI 读一遍，发现需要你做的事就加入待办并通知你")
                }
                LabeledContent {
                    Button("添加邮箱…", action: addMailAccount)
                } label: {
                    Text("邮箱账户")
                    Text("QQ、Gmail、iCloud、Outlook、企业邮箱…")
                }
            } header: {
                Text("邮件")
            }

            Section("日程与提醒") {
                Toggle(isOn: Binding(
                    get: { notifier.notifyNew && notifier.remindBefore15 && notifier.remindBefore5 },
                    set: { on in
                        notifier.notifyNew = on
                        notifier.remindBefore15 = on
                        notifier.remindBefore5 = on
                    }
                )) {
                    Text("日程通知")
                    Text("有新日程时、开始前 15 分钟和 5 分钟在右上角提醒")
                }
                Toggle(isOn: Binding(
                    get: { reminders.isEnabled },
                    set: { on in
                        if on { Task { await reminders.enable() } } else { reminders.disable() }
                    }
                )) {
                    Text("同步到「提醒事项」")
                    Text("待办出现在 iPhone、Apple Watch 上，在哪边勾掉都会同步")
                }
            }

            Section {
                ConnectRow(icon: BrandMark.github, tint: Color(white: 0.13), name: "GitHub",
                           connected: github.login != nil) { github.connecting = true }
                ConnectRow(icon: BrandMark.wecom, tint: BrandColor.wecom, name: "企业微信",
                           connected: wecom.status == .authorized) { wecom.connecting = true }
            } header: {
                Text("连接（可稍后在设置里完成）")
            }

        }
        .formStyle(.grouped)
    }
}

/// Meeting recording: when to start and stop, and who transcribes.
private struct MeetingStep: View {
    @ObservedObject var calendar: CalendarCenter
    @AppStorage(MeetingSettings.engineKey) private var engine = MeetingSettings.Engine.local.rawValue
    @AppStorage(MeetingSettings.promptOnCallKey) private var promptOnCall = true
    @AppStorage(MeetingSettings.endOnHangUpKey) private var endOnHangUp = true
    @AppStorage(MeetingSettings.liveNotesKey) private var liveNotes = true
    @AppStorage(MeetingSettings.afterModelKey) private var afterModel = ""
    @State private var hasAstraFlowKey = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { calendar.promptsToRecord },
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
                    Text("腾讯会议、Zoom、飞书、Teams 等")
                }
                Toggle(isOn: $endOnHangUp) {
                    Text("挂断后自动结束录音并生成纪要")
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("会议").font(.title2.weight(.bold)).foregroundStyle(.primary)
                    Text("录下会议，边开边出文字，结束后生成纪要和双方的待办。")
                        .font(.body).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                .textCase(nil)
            }

            Section {
                Picker(selection: $engine) {
                    Text("本机（Apple）").tag(MeetingSettings.Engine.local.rawValue)
                    Text("AstraFlow").tag(MeetingSettings.Engine.astraFlow.rawValue)
                } label: {
                    Text("实时转写")
                    Text(engineNote)
                }
                if hasAstraFlowKey {
                    Toggle(isOn: Binding(
                        get: { !afterModel.isEmpty },
                        set: { afterModel = $0 ? CloudFileTranscriber.Model.diarize.rawValue : "" }
                    )) {
                        Text("散会后用 AstraFlow 转写录音")
                        Text("没开 AstraFlow 实时转写时生效，分得出不同说话人")
                    }
                }
                Toggle(isOn: $liveNotes) {
                    Text("会中速记")
                    Text("约每 45 秒更新一次要点和待办，会持续调用 AI")
                }
            } header: {
                Text("转写")
            }
        }
        .formStyle(.grouped)
        .task { hasAstraFlowKey = CloudEndpoint.astraFlow() != nil }
    }

    private var engineNote: String {
        if engine == MeetingSettings.Engine.astraFlow.rawValue {
            return hasAstraFlowKey ? "声音发到 AstraFlow 识别，自动识别语言，可实时翻译字幕"
                : "需要先在上一步「AI 模型」里填好 AstraFlow 密钥"
        }
        return LiveTranscript.isSupported ? "在本机识别，声音不出电脑" : "本机实时转写需要 macOS 26，否则会后转写"
    }
}

private struct Feature: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
    }
}

private struct ConnectRow: View {
    let icon: NSImage
    let tint: Color
    let name: String
    let connected: Bool
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 26, height: 26)
                .overlay { BrandIcon(image: icon, size: 15).foregroundStyle(.white) }
            Text(name)
            Spacer()
            if connected {
                Label("已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("连接…", action: connect)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @ObservedObject var calendar: CalendarCenter
    @ObservedObject var notifier: EventNotifier
    @ObservedObject var reminderSync: RemindersSync

    @State private var screen = ScreenCapturer.hasPermission
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var reminders = EKEventStore.authorizationStatus(for: .reminder)
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section {
                PermissionRow(symbol: "rectangle.dashed.badge.record", tint: .blue, title: "屏幕录制",
                              detail: "截屏识别待办、录对方声音需要",
                              state: screen ? .granted : .ask, required: true,
                              settings: "Privacy_ScreenCapture") {
                    ScreenCapturer.openPermissionSettings()
                }
                PermissionRow(symbol: "bell.badge", tint: .red, title: "通知",
                              detail: "日程提醒、邮件里发现的待办",
                              state: Self.state(notifications),
                              settings: "notifications") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        await refresh()
                    }
                }
                PermissionRow(symbol: "calendar", tint: .orange, title: "日历",
                              detail: "读取日程，会议开始时提醒录音",
                              state: Self.state(EKEventStore.authorizationStatus(for: .event)),
                              settings: "Privacy_Calendars") {
                    Task { await calendar.requestAccess(); await refresh() }
                }
                PermissionRow(symbol: "checklist", tint: .indigo, title: "提醒事项",
                              detail: "待办同步到 iPhone 的「提醒事项」",
                              state: reminderSync.accessGranted ? .granted : Self.state(reminders),
                              settings: "Privacy_Reminders") {
                    Task {
                        // The answer, not authorizationStatus: that one stays stale after allowing.
                        if !(await reminderSync.requestAccess()) { reminders = .denied }
                    }
                }
                PermissionRow(symbol: "mic", tint: .pink, title: "麦克风",
                              detail: "会议录音，录音只保存在这台 Mac 上",
                              state: Self.state(mic),
                              settings: "Privacy_Microphone") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        await refresh()
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("授予权限").font(.title2.weight(.bold)).foregroundStyle(.primary)
                    Text("只有屏幕录制是必需的，其他按需开启，随时可以在系统设置里更改。")
                        .font(.body).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                .textCase(nil)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @MainActor
    private func refresh() async {
        screen = await ScreenCapturer.checkPermission()
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let current = EKEventStore.authorizationStatus(for: .reminder)
        if current != .notDetermined || reminders != .denied { reminders = current }
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func state(_ s: UNAuthorizationStatus) -> PermissionRow.State {
        switch s {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .ask
        }
    }

    static func state(_ s: EKAuthorizationStatus) -> PermissionRow.State {
        switch s {
        case .fullAccess, .authorized: .granted
        case .denied, .restricted, .writeOnly: .denied
        default: .ask
        }
    }

    static func state(_ s: AVAuthorizationStatus) -> PermissionRow.State {
        switch s {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .ask
        }
    }
}

private struct PermissionRow: View {
    enum State { case granted, ask, denied }

    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let state: State
    var required = false
    /// Privacy_* anchor of 隐私与安全性, or "notifications" for Aist's own page in 通知.
    var settings: String
    let request: () -> Void

    private var settingsURL: URL {
        if settings == "notifications" {
            let id = Bundle.main.bundleIdentifier ?? "com.jianfengmei.aist"
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settings)")!
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 30, height: 30)
                .overlay { Image(systemName: symbol).foregroundStyle(.white).font(.system(size: 14, weight: .semibold)) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if required { Text("必需").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Label("已允许", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .ask:
                Button("允许…", action: request)
            case .denied:
                Button("打开系统设置…") {
                    if settings == "Privacy_ScreenCapture" { ScreenCapturer.openPermissionSettings() }
                    else { NSWorkspace.shared.open(settingsURL) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Model

private struct ModelStep: View {
    @StateObject private var model = ProvidersModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择 AI 模型").font(.title2.weight(.bold))
                Text("截屏、邮件、会议纪要都由它来读。填好密钥后点「测试连接」，再「设为默认」。")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.builtIns) { p in
                        Button { model.selection = p.id } label: {
                            VStack(spacing: 6) {
                                ProviderLogo(provider: p, size: 34)
                                Text(p.name).font(.caption).lineLimit(1)
                            }
                            .frame(width: 74, height: 70)
                            .background(model.selection == p.id ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if model.state.active == p.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).padding(4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            if let id = model.selection, let binding = model.binding(id) {
                ProviderDetail(provider: binding, isActive: model.state.active == id,
                               activate: { model.activate(id) }, remove: {})
                    .id(id)
            }
        }
    }
}
