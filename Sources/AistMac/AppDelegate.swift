import AistCore
import AppKit
import Combine
import EventKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = TodoStore()
    private let meetings = MeetingStore()
    private let recorder = AudioRecorder()
    private let player = AudioPlayback()
    private let mailAccounts = MailAccountStore()
    private lazy var mail = MailCenter(accounts: mailAccounts)
    private lazy var composer = ComposeWindows(mail: mail)
    /// One EventKit store for calendar and reminders.
    private let ek = EKEventStore()
    private lazy var calendar = CalendarCenter(ek: ek)
    private lazy var reminders = RemindersSync(ek: ek, store: store)
    private lazy var github = GitHubCenter(store: store)
    private let wecom = WeComCenter()
    private lazy var notifier = EventNotifier(calendar: calendar)
    private lazy var mailTodos = MailAutoTodo(mail: mail, store: store)
    private var onboardingWindow: NSWindow?
    private var overlay: PanelController!
    private var mainWindow: MainWindowController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var ticker: Timer?
    private var recordingTicker: Timer?
    /// To-dos whose "due in 15 minutes" drop-down already happened this session.
    private var remindedIDs: Set<UUID> = []

    /// Dock icon on by default; 设置 › 通用 can make Aist menu-bar-only (Info.plist has LSUIElement, so this decides).
    static let showInDockKey = "app.showInDock"

    static func applyDockPolicy() {
        UserDefaults.standard.register(defaults: [showInDockKey: true])
        let show = UserDefaults.standard.bool(forKey: showInDockKey)
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show { NSApp.activate() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyDockPolicy()
        // The GUI session can reach the login keychain; move the plaintext key there.
        LLMConfig.migrateKeyToKeychain()
        Updater.shared.start()

        overlay = PanelController(store: store, meetings: meetings, recorder: recorder)
        overlay.onCapture = { [weak self] in self?.captureAndAnalyze() }
        overlay.onStartMeeting = { [weak self] in Task { await self?.startMeeting() } }
        overlay.onStopMeeting = { [weak self] in Task { await self?.stopMeeting() } }
        overlay.onOpenMain = { [weak self] pane, id in self?.mainWindow.show(pane, select: id) }
        overlay.onRecordEvent = { [weak self] event in Task { await self?.startMeeting(for: event) } }

        let actions = MainActions(
            capture: { [weak self] in self?.captureAndAnalyze() },
            startMeeting: { [weak self] in Task { await self?.startMeeting() } },
            stopMeeting: { [weak self] in Task { await self?.stopMeeting() } },
            retryMeeting: { [weak self] id in Task { await self?.process(id) } },
            recordEvent: { [weak self] event in Task { await self?.startMeeting(for: event) } }
        )
        let mailActions = MailActions(compose: { [weak self] draft in self?.composer.open(draft) })
        mainWindow = MainWindowController(store: store, meetings: meetings) { [store, meetings, recorder, player, overlay, mail, calendar, github, wecom] model in
            AnyView(MainView(model: model, store: store, meetings: meetings, recorder: recorder,
                             player: player, overlay: overlay!.model, mail: mail, calendar: calendar, github: github, wecom: wecom,
                             actions: actions, mailActions: mailActions))
        }
        mail.refreshInboxes()
        setUpCalendar()
        // "连接 GitHub…" from Settings: the sheet lives on the main window.
        github.$connecting.merge(with: wecom.$connecting).filter { $0 }
            .sink { [weak self] _ in self?.mainWindow.show() }
            .store(in: &subscriptions)
        _ = reminders
        _ = mailTodos
        // Names the AI should recognise as the user.
        mailAccounts.$accounts.combineLatest(github.$login)
            .receive(on: RunLoop.main)
            .sink { accounts, login in
                UserIdentity.discovered = accounts.flatMap { UserIdentity.from(email: $0.email, senderName: $0.senderName) }
                    + [login].compactMap { $0 }
            }
            .store(in: &subscriptions)
        NSApp.mainMenu = buildMainMenu()

        setUpStatusItem()
        overlay.anchorFrame = { [weak self] in self?.statusItem.button?.window?.frame }

        HotkeyManager.shared.onPress = { [weak self] in
            MainActor.assumeIsolated { self?.captureAndAnalyze() }
        }
        if !HotkeyManager.shared.register() {
            overlay.show(message: "快捷键 \(HotkeyManager.shared.current.display) 被占用，请在设置里更换", isError: true, for: 6)
        }

        if !Onboarding.isDone { showOnboarding() }
        NotificationCenter.default.publisher(for: Onboarding.showNotification)
            .sink { [weak self] _ in self?.showOnboarding() }
            .store(in: &subscriptions)

        // Deadlines move toward "now" without the store changing; refresh the menu bar and reminders.
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusItem()
                self?.remindDueSoon()
            }
        }
    }

    /// Clicking aist in the Dock (or opening it again from Finder) brings up the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    // MARK: Pipeline: hotkey → screenshot → LLM → panel

    func captureAndAnalyze() {
        guard !overlay.model.isBusy else { return }
        let config: LLMConfig
        do { config = try LLMConfig.load() } catch {
            overlay.show(message: error.localizedDescription, isError: true, for: 6)
            return
        }

        overlay.model.phase = .capturing
        Task { @MainActor in
            defer { overlay.model.phase = .idle }
            guard await ScreenCapturer.checkPermission() else {
                ScreenCapturer.openPermissionSettings()
                overlay.show(message: "需要录屏权限：把 Aist 拖进「录屏与系统录音」列表", isError: true, for: 8)
                return
            }
            NSSound(named: "Tink")?.play()
            do {
                let capture = try await ScreenCapturer.captureDisplayUnderMouse()
                overlay.model.phase = .analyzing
                let jpeg = try ImageCodec.jpeg(capture.image)
                let extracted = try await TodoExtractor(client: LLMClient(config: config), identity: UserIdentity.names).extract(
                    imageJPEG: jpeg,
                    context: CaptureContext(frontApp: capture.frontApp, windowTitle: capture.windowTitle),
                    existing: store.openItems
                )
                let result = store.apply(extracted, origin: .screenshot)
                if result.isEmpty {
                    overlay.show(message: extracted.isEmpty ? "这屏没有发现待办" : "这些待办已经记下了", isError: false)
                } else {
                    overlay.showResults(Set(result.added + result.updated))
                }
            } catch {
                overlay.show(message: error.localizedDescription, isError: true, for: 6)
            }
        }
    }

    // MARK: Meetings: record → on-device transcript → AI minutes → to-dos

    private func startMeeting(for event: CalEvent? = nil) async {
        guard !recorder.isRecording else { return }
        guard await ScreenCapturer.checkPermission() else {
            ScreenCapturer.openPermissionSettings()
            overlay.show(message: "录电脑声音需要录屏权限：把 Aist 拖进「录屏与系统录音」列表", isError: true, for: 8)
            return
        }
        let meeting = meetings.create()
        if let event {
            meetings.update(meeting.id) {
                $0.title = event.title
                $0.titleEdited = true
                $0.calendarEventID = event.id
                $0.attendees = event.attendees.isEmpty ? nil : event.attendees
            }
        }
        overlay.model.meetingPrompt = nil
        do {
            try await recorder.start(for: meeting.id)
        } catch {
            meetings.delete(meeting.id)
            overlay.show(message: "录音没能开始：\(error.localizedDescription)", isError: true, for: 6)
        }
    }

    private func stopMeeting() async {
        guard let (id, recording) = await recorder.stop() else { return }
        guard recording.hasMicrophone || recording.hasSystemAudio else {
            try? FileManager.default.removeItem(at: TodoStore.folder(for: recording.id))
            meetings.update(id) {
                $0.duration = recording.duration
                $0.status = .failed
                $0.error = "没有录到声音（检查麦克风权限）"
            }
            overlay.show(message: "没有录到声音（检查麦克风权限）", isError: true)
            return
        }
        meetings.update(id) {
            $0.recording = recording
            $0.duration = recording.duration
            $0.status = .transcribing
        }
        linkCalendarEvent(id)
        await process(id)
    }

    /// Transcribe (once) and summarize; also used for "重试 / 重新生成纪要".
    private func process(_ id: UUID) async {
        guard let meeting = meetings.meeting(id), let recording = meeting.recording, meeting.status != .recording else { return }
        do {
            var transcript = meeting.transcript
            if transcript == nil {
                meetings.update(id) {
                    $0.status = .transcribing
                    $0.error = nil
                }
                let segments = try await MeetingTranscriber.transcribe(recording)
                transcript = segments
                meetings.update(id) { $0.transcript = segments }
            }
            guard let transcript, !transcript.isEmpty else {
                meetings.update(id) {
                    $0.status = .failed
                    $0.error = "录音里没有识别出说话内容"
                }
                overlay.show(message: "会议录音里没有识别出说话内容", isError: true, for: 5,
                             target: .init(pane: .meetings, id: id))
                return
            }

            meetings.update(id) {
                $0.status = .summarizing
                $0.error = nil
            }
            let config = try LLMConfig.load()
            let current = meetings.meeting(id) ?? meeting
            let out = try await MeetingSummarizer(client: LLMClient(config: config), identity: UserIdentity.names).summarize(
                transcript: transcript, startedAt: current.startedAt,
                existing: store.openItems, notes: current.notes,
                calendar: calendarContext(for: current)
            )
            let title = current.titleEdited == true ? current.title : out.title
            let todos = out.myTodos.map { t -> ExtractedTodo in
                var t = t
                t.source = "会议：\(title)"
                return t
            }
            let result = store.apply(todos, origin: .meeting, meetingID: id)
            let linked = result.added + result.updated
            meetings.update(id) {
                $0.title = title
                $0.summary = out.summary
                var ids = $0.todoIDs ?? []
                for t in linked where !ids.contains(t) { ids.append(t) }
                $0.todoIDs = ids.isEmpty ? nil : ids
                $0.status = .ready
            }
            let extra = result.added.isEmpty ? "" : "，新增 \(result.added.count) 项待办"
            if !result.added.isEmpty {
                overlay.model.freshIDs = Set(result.added)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    withAnimation(.easeOut(duration: 0.8)) { self?.overlay.model.freshIDs = [] }
                }
            }
            overlay.show(message: "「\(title)」纪要已生成\(extra)", isError: false, for: 8,
                         target: .init(pane: .meetings, id: id))
        } catch {
            meetings.update(id) {
                $0.status = .failed
                $0.error = error.localizedDescription
            }
            overlay.show(message: "会议处理失败：\(error.localizedDescription)", isError: true, for: 6,
                         target: .init(pane: .meetings, id: id))
        }
    }

    // MARK: Calendar

    private func setUpCalendar() {
        notifier.onOpen = { [weak self] event in
            guard let self else { return }
            self.mainWindow.show(event.source == .wecom ? .wecom : .calendar)
            self.mainWindow.model.calendarSelection = event.id
        }
        notifier.onRecord = { [weak self] event in Task { await self?.startMeeting(for: event) } }
        wecom.$schedules
            .receive(on: RunLoop.main)
            .sink { [weak self] list in self?.calendar.setWeCom(list) }
            .store(in: &subscriptions)
        calendar.onMeetingStarting = { [weak self] event in
            guard let self, !self.recorder.isRecording else { return }
            self.overlay.model.meetingPrompt = event
            NSSound(named: "Glass")?.play()
            self.overlay.open(autoClose: 20)
        }
        calendar.$events
            .combineLatest(Timer.publish(every: 60, on: .main, in: .common).autoconnect().prepend(.now))
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                let next = self.calendar.nextToday
                if self.overlay.model.nextEvent != next { self.overlay.model.nextEvent = next }
            }
            .store(in: &subscriptions)
    }

    /// A recording started by hand still belongs to whatever meeting was on the calendar (system or WeCom)
    /// at that time; linking it gives the summarizer the attendees and agenda.
    private func linkCalendarEvent(_ id: UUID) {
        guard let m = meetings.meeting(id), m.calendarEventID == nil else { return }
        let start = m.startedAt, end = m.startedAt.addingTimeInterval(max(m.duration, 60))
        let candidates = calendar.events.filter { e in
            !e.isAllDay && e.start.addingTimeInterval(-15 * 60) <= start && e.end > start
        }
        // Most overlap wins; a real meeting (attendees / meeting link) beats a personal block.
        func score(_ e: CalEvent) -> Double {
            let overlap = min(e.end, end).timeIntervalSince(max(e.start, start))
            return overlap + (e.isMeeting ? 3600 : 0)
        }
        guard let event = candidates.max(by: { score($0) < score($1) }) else { return }
        meetings.update(id) {
            $0.calendarEventID = event.id
            if $0.attendees == nil, !event.attendees.isEmpty { $0.attendees = event.attendees }
        }
    }

    /// The meeting as the calendar (or WeCom) knows it, for the summarizer to read the transcript against.
    private func calendarContext(for meeting: Meeting) -> String? {
        var parts: [String] = []
        if let id = meeting.calendarEventID, let e = calendar.event(id) {
            parts.append("主题：\(e.title)")
            parts.append("来源：\(e.source == .wecom ? "企业微信日程" : "日历「\(e.calendarTitle)」")")
            parts.append("时间：\(DueFormatter.long(e.start))–\(DueFormatter.time(e.end))")
            if let place = e.location ?? e.room { parts.append("地点：\(place)") }
            if e.meetingCode != nil || e.url != nil { parts.append("形式：线上会议") }
            if let org = e.organizer { parts.append("组织者：\(org)") }
            let people = meeting.attendees ?? e.attendees
            if !people.isEmpty { parts.append("参会人（\(people.count) 人）：\(people.joined(separator: "、"))") }
            if let notes = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                parts.append("日程备注 / 议程：\n\(notes.prefix(2000))")
            }
        } else if let people = meeting.attendees, !people.isEmpty {
            parts.append("主题：\(meeting.title)")
            parts.append("参会人：\(people.joined(separator: "、"))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: Reminders

    private var nextDue: TodoItem? {
        store.openItems.filter { $0.dueAt != nil }.min { $0.dueAt! < $1.dueAt! }
    }

    /// Open the panel once by itself when something is due within 15 minutes.
    private func remindDueSoon() {
        let now = Date.now
        let soon = store.openItems.filter {
            guard let due = $0.dueAt else { return false }
            return due > now && due.timeIntervalSince(now) <= 15 * 60 && !remindedIDs.contains($0.id)
        }
        guard !soon.isEmpty else { return }
        remindedIDs.formUnion(soon.map(\.id))
        overlay.model.freshIDs = Set(soon.map(\.id))
        overlay.open(autoClose: 6)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        store.$items.combineLatest(overlay.model.$phase, recorder.$meetingID, meetings.$meetings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.updateStatusItem() }
            .store(in: &subscriptions)
        // While recording, the menu bar shows a live timer.
        recorder.$meetingID
            .receive(on: RunLoop.main)
            .sink { [weak self] id in
                guard let self else { return }
                self.recordingTicker?.invalidate()
                self.recordingTicker = id == nil ? nil : Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateStatusItem() }
                }
            }
            .store(in: &subscriptions)
    }

    /// The menu bar is where reminding happens, escalating as the nearest deadline approaches:
    /// `logo 3` (quiet) → amber ⏰ when a deadline is within 2h → red ! when one is overdue. No times in the bar.
    /// Drawn checkbox + sparkle (MenuGlyph): crisp at 16 px, where the anime face turned into a blob.
    private static let menuLogo: NSImage? = MenuGlyph.make()

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let count = store.openItems.count
        var symbol: String? // nil = the Aist logo
        var text = count > 0 ? " \(count)" : ""
        var tint: NSColor?

        if recorder.isRecording, let start = recorder.startedAt {
            symbol = "record.circle"
            tint = .systemRed
            text = " " + DueFormatter.duration(Date.now.timeIntervalSince(start))
        } else if overlay.model.isBusy {
            symbol = "text.viewfinder"
            text = " 读屏中…"
        } else if meetings.meetings.contains(where: \.isProcessing) {
            symbol = "waveform"
            text = " 整理纪要…"
        } else if let next = nextDue, let due = next.dueAt {
            // Only the icon signals urgency; deadlines live in the panel, not the menu bar.
            let minutes = due.timeIntervalSinceNow / 60
            if minutes < 0 {
                symbol = "exclamationmark.circle"
                tint = .systemRed
            } else if minutes <= 120 {
                symbol = "alarm"
                tint = .systemOrange
            }
        }

        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Aist") } ?? Self.menuLogo
        button.contentTintColor = tint
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .baselineOffset: 0.5,
        ]
        // Only the small icon carries urgency; colored text in the menu bar is too loud.
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    /// Left click opens / closes the panel; right click (or ⌃-click) opens the menu.
    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            overlay.toggle()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开 Aist", action: #selector(menuOpenMain), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "截屏分析待办（\(HotkeyManager.shared.current.display)）", action: #selector(menuCapture), keyEquivalent: "")
        if recorder.isRecording {
            menu.addItem(withTitle: "结束会议录音", action: #selector(menuStopMeeting), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "开始会议录音", action: #selector(menuStartMeeting), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "新手引导…", action: #selector(menuOnboarding), keyEquivalent: "")
        menu.addItem(withTitle: "检查更新…", action: #selector(menuCheckUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "退出 Aist", action: #selector(menuQuit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func menuOpenMain() { mainWindow.show() }
    @objc private func menuCapture() { captureAndAnalyze() }
    @objc private func menuStartMeeting() { Task { await startMeeting() } }
    @objc private func menuStopMeeting() { Task { await stopMeeting() } }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuCheckUpdates() { Task { await Updater.shared.check(userInitiated: true) } }

    /// The app menu bar shown while the main window is up. Without an Edit menu,
    /// ⌘C / ⌘V / ⌘A / ⌘Z don't reach text fields.
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "aist")
        app.addItem(withTitle: "关于 Aist", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let updates = app.addItem(withTitle: "检查更新…", action: #selector(menuCheckUpdates), keyEquivalent: "")
        updates.target = self
        let settings = app.addItem(withTitle: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 Aist", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "退出 Aist", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "文件")
        let capture = file.addItem(withTitle: "截屏分析待办", action: #selector(menuCapture), keyEquivalent: "")
        capture.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "粘贴并匹配样式", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = NSMenu(title: "帮助")
        help.addItem(withTitle: "新手引导…", action: #selector(menuOnboarding), keyEquivalent: "").target = self
        NSApp.helpMenu = help

        for sub in [app, file, edit, window, help] {
            let item = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            item.submenu = sub
            main.addItem(item)
        }
        return main
    }

    @objc private func menuOnboarding() { showOnboarding() }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                calendar: calendar, reminders: reminders, notifier: notifier, mailTodos: mailTodos,
                github: github, wecom: wecom,
                finish: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Onboarding.doneKey)
                    self?.onboardingWindow?.close()
                    self?.mainWindow.show()
                },
                addMailAccount: { [weak self] in
                    self?.mainWindow.show()
                    self?.mainWindow.model.addingAccount = true
                }
            )
            onboardingWindow = Onboarding.makeWindow(view)
        }
        onboardingWindow?.center()
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func menuSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(reminders: reminders, calendar: calendar, notifier: notifier, mailTodos: mailTodos, github: github, wecom: wecom)
        }
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
