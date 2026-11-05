import AistAgentUI
import AistCore
import AppKit
import Combine
import EventKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = TodoStore()
    private let meetings = MeetingStore()
    /// The to-do list in iCloud, shared with the iPhone app (off unless the build is signed for iCloud).
    private lazy var cloud = CloudSync(store: store)
    private var cloudTimer: Timer?
    private let recorder = AudioRecorder()
    private lazy var liveWindow = LiveMeetingWindow(recorder: recorder)
    private let calls = CallWatcher()
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
    private lazy var agent = AgentHub()
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

    /// Testing hooks: `-aistOpenPane chat` opens the main window at a pane; `-aistAsk "<question>"`
    /// also sends a question there. Only act when passed explicitly on the command line.
    private static var clickSerial = 1000

    private func openFromLaunchArguments() {
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        // -aistShots <dir>: snapshot every Settings pane and the onboarding steps to <dir>, then quit.
        if let dir = args["aistShots"] as? String {
            Task { @MainActor [weak self] in await self?.shootWindows(into: dir) }
            return
        }
        // -aistCloudTest <a.wav[,b.wav]>: play files as "others" (and "me") through the cloud engine,
        // log lines to /tmp/aist-cloud.log, then quit.
        if let files = args["aistCloudTest"] as? String {
            Task { @MainActor in await CloudSelfTest.run(files.split(separator: ",").map(String.init)) }
            return
        }
        guard let pane = args["aistOpenPane"] as? String else { return }
        FileManager.default.createFile(atPath: "/tmp/aist-nav.log", contents: nil)
        NavTrace.file = FileHandle(forWritingAtPath: "/tmp/aist-nav.log")
        switch pane {
        case "chat":
            mainWindow.show(.chat)
            // -aistOpenConversation <id prefix>: show that saved conversation once the list is loaded.
            if let prefix = args["aistOpenConversation"] as? String {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let self, let id = self.agent.library.conversations.first(where: { $0.id.uuidString.hasPrefix(prefix.uppercased()) })?.id else { return }
                    self.mainWindow.show(.conversation(id))
                }
            }
            if args["aistPickModel"] != nil { agent.session.pickingModel = true }
            if let q = args["aistAsk"] as? String, !q.isEmpty {
                agent.session.draft = q
                agent.session.send()
            }
        case "todos": mainWindow.show(.todos)
        default: break
        }
        // -aistCycle <seconds>: switch between the first saved conversations on that interval and
        // log every main-thread stall over 50 ms to /tmp/aist-cycle.log (for profiling with `sample`).
        if let every = (args["aistCycle"] as? String).flatMap(Double.init) {
            let log = FileHandle(forWritingAtPath: "/tmp/aist-cycle.log") ?? {
                FileManager.default.createFile(atPath: "/tmp/aist-cycle.log", contents: nil)
                return FileHandle(forWritingAtPath: "/tmp/aist-cycle.log")!
            }()
            log.seekToEndOfFile()
            func note(_ s: String) { log.write("\(Date().formatted(date: .omitted, time: .standard)) \(s)\n".data(using: .utf8)!) }
            var last = CFAbsoluteTimeGetCurrent()
            // Main thread time lost since the last switch: every gap over a 120 Hz frame counts.
            var blocked = 0.0, worst = 0.0
            let stall = Timer(timeInterval: 0.008, repeats: true) { _ in
                let now = CFAbsoluteTimeGetCurrent()
                let gap = now - last
                if gap > 0.012 {
                    blocked += gap - 0.008; worst = max(worst, gap)
                    note(String(format: "    gap %.0f ms", gap * 1000))
                }
                last = now
            }
            RunLoop.main.add(stall, forMode: .common)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let ids = self.agent.library.conversations.prefix(8).map(\.id)
                note("cycling \(ids.count) conversations every \(every)s")
                for n in 0..<40 {
                    guard !ids.isEmpty else { break }
                    let id = ids[n % ids.count]
                    if n > 0 { note(String(format: "  blocked %.0f ms, worst gap %.0f ms", blocked * 1000, worst * 1000)) }
                    blocked = 0; worst = 0
                    self.mainWindow.show(.conversation(id))
                    note(String(format: "switch #%d -> %@", n, id.uuidString.prefix(8) as CVarArg))
                    try? await Task.sleep(for: .seconds(every))
                }
                note(String(format: "  blocked %.0f ms, worst gap %.0f ms", blocked * 1000, worst * 1000))
                note("done")
            }
        }
        // -aistClick "x,y[;x,y…]": synthesised clicks at window points (from the top-left), 1.5 s apart,
        // starting 2 s in; the resulting pane is logged to /tmp/aist-cycle.log.
        if let spec = args["aistClick"] as? String {
            let points = spec.split(separator: ";").compactMap { pair -> NSPoint? in
                let xy = pair.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return xy.count == 2 ? NSPoint(x: xy[0], y: xy[1]) : nil
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
                      let content = window.contentView else { return }
                let log = FileHandle(forWritingAtPath: "/tmp/aist-cycle.log") ?? {
                    FileManager.default.createFile(atPath: "/tmp/aist-cycle.log", contents: nil)
                    return FileHandle(forWritingAtPath: "/tmp/aist-cycle.log")!
                }()
                log.seekToEndOfFile()
                for p in points {
                    let location = NSPoint(x: p.x, y: content.bounds.height - p.y)
                    if let hit = content.hitTest(location) {
                        let f = hit.convert(hit.bounds, to: nil)
                        NavTrace.log("click.hit \(type(of: hit)) frame y=\(Int(content.bounds.height - f.maxY))..\(Int(content.bounds.height - f.minY)) order=\(self.agent.library.conversations.prefix(6).map { String($0.id.uuidString.prefix(4)) }.joined(separator: ","))")
                    }
                    // Down, a human-length press, up — SwiftUI's press tracking wants the gap.
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        Self.clickSerial += 1
                        if let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: Self.clickSerial, clickCount: 1, pressure: 1) {
                            NSApp.sendEvent(e)
                        }
                        if type == .leftMouseDown { try? await Task.sleep(for: .milliseconds(70)) }
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                    let line = "\(Date().formatted(date: .omitted, time: .standard)) clicked \(p.x),\(p.y) -> pane \(self.mainWindow.model.pane)\n"
                    log.write(line.data(using: .utf8)!)
                }
            }
        }
        // -aistSnapshot <path.png>: write the window to a file every 3 s (each shot to <path>-<n>.png).
        if let path = args["aistSnapshot"] as? String {
            Task { @MainActor [weak self] in
                for n in 1...20 {
                    try? await Task.sleep(for: .seconds(3))
                    self?.mainWindow.snapshot(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(n).png")))
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MeetingSettings.registerDefaults()
        Self.applyDockPolicy()
        // The GUI session can reach the login keychain; move the plaintext key there.
        LLMConfig.migrateKeyToKeychain()
        Updater.shared.start()
        setUpCloudSync()

        overlay = PanelController(store: store, meetings: meetings, recorder: recorder)
        overlay.onCapture = { [weak self] in self?.captureAndAnalyze() }
        overlay.onStartMeeting = { [weak self] in Task { await self?.startMeeting() } }
        overlay.onStopMeeting = { [weak self] in Task { await self?.stopMeeting() } }
        overlay.onShowLive = { [weak self] in self?.liveWindow.show() }
        overlay.onOpenMain = { [weak self] pane, id in self?.mainWindow.show(pane, select: id) }
        overlay.onRecordEvent = { [weak self] event in Task { await self?.startMeeting(for: event) } }

        let actions = MainActions(
            capture: { [weak self] in self?.captureAndAnalyze() },
            startMeeting: { [weak self] in Task { await self?.startMeeting() } },
            stopMeeting: { [weak self] in Task { await self?.stopMeeting() } },
            retryMeeting: { [weak self] id in Task { await self?.process(id) } },
            emailMinutes: { [weak self] id in self?.emailMinutes(id) },
            showLive: { [weak self] in self?.liveWindow.show() },
            recordEvent: { [weak self] event in Task { await self?.startMeeting(for: event) } }
        )
        let mailActions = MailActions(compose: { [weak self] draft in self?.composer.open(draft) })
        mainWindow = MainWindowController(store: store, meetings: meetings) { [store, meetings, recorder, player, overlay, mail, calendar, github, wecom, agent] model in
            AnyView(MainView(model: model, store: store, meetings: meetings, recorder: recorder,
                             player: player, overlay: overlay!.model, mail: mail, calendar: calendar, github: github, wecom: wecom,
                             agent: agent, actions: actions, mailActions: mailActions))
        }
        mail.refreshInboxes()
        setUpCalendar()
        setUpLiveMeeting()
        // "连接 GitHub…" from Settings: the sheet lives on the main window.
        github.$connecting.merge(with: wecom.$connecting).filter { $0 }
            .sink { [weak self] _ in self?.mainWindow.show() }
            .store(in: &subscriptions)
        _ = reminders
        _ = mailTodos
        openFromLaunchArguments()
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

    private func setUpCloudSync() {
        guard cloud.isEnabled else { return }
        NSApp.registerForRemoteNotifications()
        cloud.sync()
        // Pushes can be missed (asleep, offline); poll now and then, and after waking up.
        cloudTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cloud.sync() }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.cloud.sync() }
            .store(in: &subscriptions)
    }

    /// CloudKit's silent push: the iPhone changed something.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        cloud.sync()
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
        if let event, event.isCall {
            // A call noticed in a meeting app: named after the app until the minutes find a title.
            meetings.update(meeting.id) { $0.title = event.title }
        } else if let event {
            meetings.update(meeting.id) {
                $0.title = event.title
                $0.titleEdited = true
                $0.calendarEventID = event.id
                $0.attendees = event.attendees.isEmpty ? nil : event.attendees
                $0.attendeeEmails = event.attendeeEmails.isEmpty ? nil : event.attendeeEmails
            }
        }
        overlay.model.meetingPrompt = nil
        do {
            try await recorder.start(for: meeting.id, language: MeetingSettings.language,
                                     translateTo: MeetingSettings.translateTo)
            recorder.session.begin()
            if MeetingSettings.showLiveWindow, LiveTranscript.isSupported { liveWindow.show() }
        } catch {
            meetings.delete(meeting.id)
            overlay.show(message: "录音没能开始：\(error.localizedDescription)", isError: true, for: 6)
        }
    }

    /// `discardIfSilent`: ended because nobody spoke; with nothing heard there's nothing to keep.
    private func stopMeeting(discardIfSilent: Bool = false) async {
        recorder.session.end()
        liveWindow.hide()
        guard let (id, recording, live) = await recorder.stop() else { return }
        if discardIfSilent, let live, live.isEmpty {
            try? FileManager.default.removeItem(at: TodoStore.folder(for: recording.id))
            meetings.delete(id)
            overlay.show(message: "没有人说话，已停止会议录音", isError: false)
            return
        }
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
            // Transcribed live: the minutes can start right away. Nothing heard live → try the files.
            if let live, !live.isEmpty { $0.transcript = live }
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
            if $0.attendeeEmails == nil, !event.attendeeEmails.isEmpty { $0.attendeeEmails = event.attendeeEmails }
        }
    }

    /// Opens a mail with the minutes and both sides' to-dos, addressed to the attendees.
    private func emailMinutes(_ id: UUID) {
        guard let m = meetings.meeting(id) else { return }
        guard let account = mailAccounts.accounts.first else {
            overlay.show(message: "先在「邮件」里添加一个邮箱账户，才能发送纪要", isError: true, for: 6)
            return
        }
        let mine = Set(mailAccounts.accounts.map { $0.email.lowercased() })
        let todos = (m.todoIDs ?? []).compactMap { tid in store.items.first { $0.id == tid } }.map {
            MeetingExport.Todo(title: $0.title, due: DueFormatter.string($0.dueAt) ?? $0.dueText, done: $0.status == .done)
        }
        var draft = ComposeDraft.new(from: account.id)
        draft.to = (m.attendeeEmails ?? []).filter { !mine.contains($0.lowercased()) }.joined(separator: ", ")
        draft.subject = "会议纪要：\(m.title)"
        let me = account.senderName ?? UserIdentity.names.first ?? "我"
        draft.body = MeetingExport.mailBody(m, myTodos: todos, myName: me)
        composer.open(draft)
    }

    // MARK: Live meeting: notes while recording, ending it, noticing calls

    private func setUpLiveMeeting() {
        let session = recorder.session
        session.makeWriter = {
            guard let config = try? LLMConfig.load() else { return nil }
            return LiveNotesWriter(client: LLMClient(config: config), identity: UserIdentity.names)
        }
        session.calendarContext = { [weak self] in
            guard let self, let id = self.recorder.meetingID, let m = self.meetings.meeting(id) else { return nil }
            return self.calendarContext(for: m)
        }
        session.onEnd = { [weak self] reason in
            guard let self else { return }
            switch reason {
            case let .appLeft(name):
                self.overlay.show(message: "\(name.isEmpty ? "会议软件" : name)已挂断，正在生成纪要", isError: false)
                Task { await self.stopMeeting() }
            case .silence:
                self.overlay.show(message: "长时间没人说话，已结束录音并生成纪要", isError: false)
                Task { await self.stopMeeting() }
            case .nobodySpoke:
                Task { await self.stopMeeting(discardIfSilent: true) }
            }
        }
        liveWindow.onStop = { [weak self] in Task { await self?.stopMeeting() } }
        liveWindow.onOpenMeeting = { [weak self] in
            guard let self, let id = self.recorder.meetingID else { return }
            self.mainWindow.show(.meetings, select: id)
        }
        calls.onPoll = { [weak self] calls in
            guard let self, self.recorder.isRecording else { return }
            self.recorder.session.tick(calls: calls)
        }
        calls.onCallStarted = { [weak self] bundleID, name in
            guard let self, MeetingSettings.promptOnCall, !self.recorder.isRecording, self.overlay.model.meetingPrompt == nil else { return }
            // The calendar meeting going on now, if there is one; else the call itself.
            let now = Date.now
            let event = self.calendar.events.first { e in
                !e.isAllDay && e.isMeeting && e.start.addingTimeInterval(-10 * 60) <= now && now < e.end
            } ?? CalEvent.call(app: name, bundleID: bundleID)
            self.overlay.model.meetingPrompt = event
            NSSound(named: "Glass")?.play()
            self.overlay.open(autoClose: 20)
        }
        calls.start()
        installDebugCommands()
    }

    /// Lets a test script drive meetings on a dev Mac (`defaults write com.jianfengmei.aist debug.commands -bool YES`):
    /// `notifyutil`-style distributed notifications "aist.debug.start" / "aist.debug.stop" / "aist.debug.dump".
    private func installDebugCommands() {
        guard UserDefaults.standard.bool(forKey: "debug.commands") else { return }
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("aist.debug.start"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.startMeeting() } }
        }
        center.addObserver(forName: .init("aist.debug.stop"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.stopMeeting() } }
        }
        // Removes test meetings (ids in the notification's object, comma-separated) and their to-dos,
        // through the stores so iCloud and Reminders see the deletions.
        center.addObserver(forName: .init("aist.debug.cleanup"), object: nil, queue: .main) { [weak self] note in
            let ids = ((note.object as? String) ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            MainActor.assumeIsolated {
                guard let self else { return }
                for id in ids {
                    if let m = self.meetings.meeting(id) { self.store.delete(m.todoIDs ?? []) }
                    self.meetings.delete(id)
                }
                self.cloud.sync()
            }
        }
        center.addObserver(forName: .init("aist.debug.retry"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.meetings.sorted.first else { return }
                Task { await self.process(m.id) }
            }
        }
        center.addObserver(forName: .init("aist.debug.dump"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let live = self.recorder.live
                var out = "status=\(live.status ?? "-") langs=\(live.languages) running=\(live.isRunning)\n"
                out += "drafts=\(live.drafts)\n"
                for l in live.shownLines {
                    out += "[\(MeetingTime.stamp(l.start))] \(l.speaker.rawValue): \(l.text)" + (l.translation.map { " | \($0)" } ?? "") + "\n"
                }
                out += "notes=\(self.recorder.session.notesState) \(self.recorder.session.notes)\n"
                out += "ending=\(String(describing: self.recorder.session.ending)) calls=\(CallWatcher.currentCalls()) readers=\(CallWatcher.readers())\n"
                if let m = self.meetings.sorted.first {
                    out += "latest meeting: \(m.title) status=\(m.status) error=\(m.error ?? "-") lines=\(m.transcript?.count ?? -1)\n"
                    out += "summary=\(String(describing: m.summary))\n"
                }
                try? out.write(toFile: "/tmp/aist-debug.txt", atomically: true, encoding: .utf8)
            }
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

    private func shootWindows(into dir: String) async {
        func shoot(_ window: NSWindow?, _ name: String) {
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        menuSettings()
        if let tabs = settingsWindow?.contentViewController as? NSTabViewController {
            for i in tabs.tabViewItems.indices {
                tabs.selectedTabViewItemIndex = i
                try? await Task.sleep(for: .seconds(1.5))
                shoot(settingsWindow, "settings-\(i)")
                for (n, popover) in NSApp.windows.filter({ $0.isVisible && $0.className.contains("Popover") }).enumerated() {
                    shoot(popover, "settings-\(i)-popover-\(n)")
                }
            }
        }
        settingsWindow?.close()
        for step in [1, 3, 4] {
            onboardingWindow?.close()
            onboardingWindow = nil
            showOnboarding(step: step)
            try? await Task.sleep(for: .seconds(1.5))
            shoot(onboardingWindow, "onboarding-\(step)")
        }
        exit(0)
    }

    private func showOnboarding(step: Int = 0) {
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
                },
                initialStep: step
            )
            onboardingWindow = Onboarding.makeWindow(view)
        }
        onboardingWindow?.center()
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func menuSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(cloud: cloud, reminders: reminders, calendar: calendar, notifier: notifier, mailTodos: mailTodos, github: github, wecom: wecom)
        }
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
