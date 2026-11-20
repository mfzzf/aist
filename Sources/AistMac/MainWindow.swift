import AistAgentUI
import AistAudio
import AistCore
import AppKit
import SwiftUI

/// Where the main window is and what it shows.
@MainActor
final class MainModel: ObservableObject {
    enum Pane: Hashable {
        case todos, calendar, meetings, done, github, wecom
        /// 问答 with a new, empty conversation.
        case chat
        /// 问答 with a saved conversation.
        case conversation(UUID)
        /// One mail account's folder.
        case mail(UUID, String)

        var isChat: Bool {
            switch self {
            case .chat, .conversation: true
            default: false
            }
        }

        var mailAccount: UUID? {
            if case let .mail(id, _) = self { return id }
            return nil
        }
    }

    @Published var pane: Pane = .todos {
        didSet { if pane != oldValue { mailSelection = nil } }
    }
    @Published var selection: UUID?
    /// The open message (MailHeader.id) when a mail folder is showing.
    @Published var mailSelection: String?
    /// The open event (CalEvent.id) when the calendar is showing.
    @Published var calendarSelection: String?
    /// The open notification thread when GitHub is showing.
    @Published var githubSelection: String?
    @Published var query = ""
    @Published var addingAccount = false
}

struct MainActions {
    var capture: () -> Void
    /// 语音记待办: start listening, or finish when already listening.
    var voice: () -> Void
    var startMeeting: () -> Void
    var stopMeeting: () -> Void
    var retryMeeting: (UUID) -> Void
    /// Write the minutes and both sides' to-dos as a mail to the attendees: the meeting, and an
    /// earlier version of its minutes to send instead of the current ones.
    var emailMinutes: (UUID, UUID?) -> Void
    /// Bring up the "会议实况" window.
    var showLive: () -> Void
    /// Record a calendar meeting, named after the event.
    var recordEvent: (CalEvent) -> Void
}

/// The full app window: everything that takes more than a glance — editing a to-do, notes,
/// history, meeting minutes and transcripts. aist shows in the Dock only while it's open.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let model = MainModel()
    private var window: NSWindow?
    private let makeRoot: (MainModel) -> AnyView
    private let store: TodoStore
    private let meetings: MeetingStore

    init(store: TodoStore, meetings: MeetingStore, makeRoot: @escaping (MainModel) -> AnyView) {
        self.store = store
        self.meetings = meetings
        self.makeRoot = makeRoot
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Bring the window up, optionally at a pane and/or one to-do or meeting.
    func show(_ pane: MainModel.Pane? = nil, select id: UUID? = nil, mail: String? = nil) {
        let window = self.window ?? build()
        if let pane, case .mail = pane {
            model.pane = pane
            model.query = ""
            model.mailSelection = mail
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        if let id {
            if let item = store.items.first(where: { $0.id == id }) {
                model.pane = item.status == .done ? .done : .todos
            } else if meetings.meeting(id) != nil {
                model.pane = .meetings
            }
            model.query = ""
            model.selection = id
        } else if let pane, pane != model.pane {
            model.pane = pane
            model.selection = nil
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSWindow {
        let host = NSHostingController(rootView: makeRoot(model))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentViewController = host
        window.title = "Aist"
        window.toolbarStyle = .unified
        window.minSize = CGSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(CGSize(width: 1040, height: 680))
        window.center()
        window.setFrameAutosaveName("aist.main")
        self.window = window
        return window
    }

    /// Testing hook: the window's contents as PNG (drawn from the view tree, so it works with the
    /// screen locked and without screen-recording permission).
    func snapshot(to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Root

struct MainView: View {
    @ObservedObject var model: MainModel
    @ObservedObject var store: TodoStore
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var player: AudioPlayback
    @ObservedObject var overlay: OverlayModel
    @ObservedObject var mail: MailCenter
    @ObservedObject var calendar: CalendarCenter
    @ObservedObject var github: GitHubCenter
    @ObservedObject var wecom: WeComCenter
    @ObservedObject var agent: AgentHub
    let actions: MainActions
    let mailActions: MailActions

    @State private var adding = false
    @State private var newTitle = ""

    private var sidebar: some View {
        Sidebar(model: model, store: store, meetings: meetings, recorder: recorder, mail: mail, calendar: calendar,
                github: github, wecom: wecom, agent: agent)
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
    }

    private var threeColumns: some View {
        NavigationSplitView {
            sidebar
        } content: {
            Group {
                switch model.pane {
                case .todos, .done:
                    TodoListColumn(model: model, store: store, meetings: meetings)
                case .calendar:
                    CalendarListColumn(model: model, calendar: calendar, meetings: meetings)
                case .wecom:
                    CalendarListColumn(model: model, calendar: calendar, meetings: meetings, source: .wecom)
                case .github:
                    GitHubListColumn(model: model, github: github)
                case .meetings:
                    MeetingListColumn(model: model, meetings: meetings, recorder: recorder, player: player, actions: actions)
                case let .mail(account, folder):
                    MailListColumn(model: model, mail: mail, account: account, folder: folder, actions: mailActions)
                        .id(model.pane)
                case .chat, .conversation:
                    EmptyView()
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
            .toolbar { toolbar }
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 360, ideal: 480)
        }
    }

    var body: some View {
        Group {
            if model.pane.isChat {
                // Conversations live in the sidebar, so the chat takes the rest of the window.
                NavigationSplitView {
                    sidebar
                } detail: {
                    ChatPane(session: agent.session, library: agent.library)
                        .navigationSplitViewColumnWidth(min: 420, ideal: 760)
                        .toolbar { toolbar }
                }
            } else {
                threeColumns
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: model.pane.isChat ? "搜索对话" : "搜索")
        // These handlers only touch ObservableObjects, and Combine publishes from inside a SwiftUI
        // update are undefined behaviour (seen: the layout re-entered itself until the app hung).
        // So every one of them hops to the next run-loop turn first.
        .onChange(of: model.query) { _, q in
            Task { @MainActor in if model.pane.isChat { agent.library.query = q } }
        }
        .onChange(of: model.pane) { old, pane in
            Task { @MainActor in paneChanged(from: old, to: pane) }
        }
        // Keeps the pane on the conversation the session shows (a new conversation gets its id
        // with the first answer). Its own view, so it reacts to the session at once: as an
        // onChange here it only ran when MainView happened to re-render, fired with a stale id,
        // and bounced the pane back and forth.
        .background(ConversationPaneSync(session: agent.session, model: model))
        .navigationTitle(title)
        .alert("新建待办", isPresented: $adding) {
            TextField("要做的事", text: $newTitle)
            Button("添加") {
                if let id = store.addManual(title: newTitle) {
                    model.pane = .todos
                    model.selection = id
                }
                newTitle = ""
            }
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) { newTitle = "" }
        }
        .sheet(isPresented: $wecom.connecting) {
            ConnectWeComView(wecom: wecom)
        }
        .sheet(isPresented: $github.connecting) {
            ConnectGitHubView(github: github) { model.pane = .github }
        }
        .sheet(isPresented: $model.addingAccount) {
            AddAccountView(mail: mail) { id in
                model.pane = .mail(id, mail.inbox(of: id))
            }
        }
    }

    private func paneChanged(from old: MainModel.Pane, to pane: MainModel.Pane) {
        NavTrace.log("paneChanged \(old) -> \(pane)")
        if !pane.isChat, !agent.library.query.isEmpty { agent.library.query = "" }
        if case let .conversation(id) = pane { agent.library.selection.selected = id }
        else { agent.library.selection.selected = nil }
        switch pane {
        case let .conversation(id):
            agent.session.open(id)
        case .chat:
            // 问答 itself = a new conversation (unless one is still being answered).
            if agent.session.conversationID != nil, !agent.session.isRunning { agent.session.reset() }
        default: break
        }
        if pane.isChat, !old.isChat {
            agent.refreshModels()
            agent.session.prefetch(agent.library.conversations.prefix(20).map(\.id))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.pane.isChat {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    agent.session.reset()
                    model.pane = .chat
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                .help("新对话")
                .keyboardShortcut("n")
            }
        } else if model.pane == .calendar || model.pane == .wecom {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    calendar.reload()
                    Task { await wecom.refreshSchedules() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help(wecom.lastRefresh.map { "刷新日程（企业微信每 2 分钟自动刷新，上次 \(DueFormatter.time($0))）" } ?? "刷新日程")
                .keyboardShortcut("r")
                .disabled(wecom.refreshing)
            }
        } else if model.pane == .github {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await github.refresh(force: true) } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新 GitHub 通知")
                .keyboardShortcut("r")
                .disabled(github.loading)
            }
        } else if case let .mail(account, folder) = model.pane {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { mailActions.compose(.new(from: account)) } label: {
                    Label("写邮件", systemImage: "square.and.pencil")
                }
                .help("写邮件")
                .keyboardShortcut("n")
                Button { Task { await mail.refresh(account, folder: folder) } } label: {
                    Label("收取邮件", systemImage: "arrow.clockwise")
                }
                .help("收取邮件")
                .keyboardShortcut("r")
                .disabled(mail.loading.contains(mail.key(account, folder)))
            }
        } else {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { adding = true } label: {
                Label("新建待办", systemImage: "plus")
            }
            .help("新建待办")
            .keyboardShortcut("n")

            Button(action: actions.capture) {
                Label("截屏分析", systemImage: "text.viewfinder")
            }
            .disabled(overlay.isBusy)
            .help("截屏分析待办（\(HotkeyManager.shared.current.display)）")

            Button(action: actions.voice) {
                Label("语音记待办", systemImage: "mic")
            }
            .help("语音记待办：按住 \(HotkeyManager.voice.current.display) 说话，或点一下开始、再点一下结束")

            if recorder.isRecording, let start = recorder.startedAt {
                Button(action: actions.stopMeeting) {
                    Label {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text("结束 " + DueFormatter.duration(ctx.date.timeIntervalSince(start))).monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .help("结束录音，生成会议纪要")
            } else {
                Button(action: actions.startMeeting) {
                    Label("会议录音", systemImage: "waveform")
                }
                .help("开始会议录音（麦克风 + 系统声音）")
            }
        }
        }
    }

    private var title: String {
        switch model.pane {
        case .todos: "待办"
        case .calendar: "日程"
        case .github: "GitHub"
        case .wecom: "企业微信"
        case .meetings: "会议"
        case .done: "已完成"
        case .chat: "新对话"
        case .conversation: "问答"
        case let .mail(account, folder):
            mail.folders(of: account).first { $0.name == folder }?.title ?? folder
        }
    }

    @ViewBuilder private var detail: some View {
        if case let .mail(account, _) = model.pane {
            if let id = model.mailSelection, let header = mail.header(account, id: id) {
                MailDetail(header: header, account: account, model: model, mail: mail, store: store, actions: mailActions)
                    .id(id)
            } else {
                ContentUnavailableView("未选择邮件", systemImage: "envelope")
            }
        } else if model.pane == .github {
            if let id = model.githubSelection, let n = github.notifications.first(where: { $0.id == id }) {
                GitHubDetail(notification: n, model: model, github: github)
                    .id(id)
            } else {
                ContentUnavailableView("未选择通知", systemImage: "bell")
            }
        } else if model.pane == .calendar || model.pane == .wecom {
            if let id = model.calendarSelection, let event = calendar.event(id) {
                EventDetail(event: event, model: model, calendar: calendar, meetings: meetings, recorder: recorder, actions: actions)
                    .id(id)
            } else {
                ContentUnavailableView("未选择日程", systemImage: "calendar")
            }
        } else if let id = model.selection, let item = store.items.first(where: { $0.id == id }) {
            TodoDetail(item: item, model: model, store: store, meetings: meetings, calendar: calendar)
                .id(id)
        } else if let id = model.selection, let meeting = meetings.meeting(id) {
            MeetingDetail(meeting: meeting, model: model, store: store, meetings: meetings,
                          recorder: recorder, player: player, actions: actions)
                .id(id)
        } else {
            BrandEmptyState(
                title: model.pane == .meetings ? "未选择会议" : "未选择待办",
                hint: model.pane == .meetings
                    ? "开会时点菜单栏的 🎙 开始录音，结束后自动生成纪要"
                    : "按 \(HotkeyManager.shared.current.display) 截屏识别待办，或按 ⌘N 新建"
            )
        }
    }
}

// MARK: - 问答

/// The chat, titled with the conversation's name (observed here so streaming doesn't redraw the window).
private struct ChatPane: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var library: AgentLibrary

    var body: some View {
        AgentChatView(session: session, style: .full,
                      suggestions: ["今天有什么科技新闻？", "帮我比较一下 SwiftData 和 Core Data", "解释一下什么是 RAG"])
            .navigationTitle(title)
    }

    private var title: String {
        guard let id = session.conversationID else { return "新对话" }
        return session.title ?? library.conversations.first { $0.id == id }?.title ?? "问答"
    }
}

/// Mirrors `session.conversationID` into `model.pane` while the Q&A pane is up.
private struct ConversationPaneSync: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var model: MainModel

    var body: some View {
        Color.clear
            .onChange(of: session.conversationID) { _, id in
                Task { @MainActor in
                    guard model.pane.isChat else { return }
                    let pane: MainModel.Pane = id.map { .conversation($0) } ?? .chat
                    if model.pane != pane {
                        NavTrace.log("conversationID changed -> pane \(pane) (was \(model.pane))")
                        model.pane = pane
                    }
                }
            }
    }
}

/// Saved conversations at the bottom of the sidebar.
private struct ChatSidebarSection: View {
    @ObservedObject var model: MainModel
    @ObservedObject var library: AgentLibrary
    let session: AgentSession

    var body: some View {
        if !library.conversations.isEmpty {
            Section(library.query.isEmpty ? "对话" : "对话 · 搜索结果") {
                ConversationRows(library: library) { id in
                    model.pane = .conversation(id)
                } onDelete: { id in
                    if model.pane == .conversation(id) {
                        session.reset()
                        model.pane = .chat
                    }
                }
            }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: MainModel
    @ObservedObject var store: TodoStore
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var mail: MailCenter
    @ObservedObject var calendar: CalendarCenter
    @ObservedObject var github: GitHubCenter
    @ObservedObject var wecom: WeComCenter
    @ObservedObject var agent: AgentHub

    var body: some View {
        List(selection: Binding(
            get: { model.pane },
            set: { pane in
                NavTrace.log("list.selection set \(String(describing: pane)) (pane \(model.pane))")
                guard let pane, pane != model.pane else { return }
                model.pane = pane
                model.selection = nil
            }
        )) {
            Label("待办", systemImage: "checklist")
                .badge(store.openItems.count)
                .tag(MainModel.Pane.todos)
            Label("日程", systemImage: "calendar")
                .badge(calendar.upcoming.filter { Calendar.current.isDateInToday($0.start) }.count)
                .tag(MainModel.Pane.calendar)
            Label("会议", systemImage: "waveform")
                .badge(meetings.meetings.count)
                .tag(MainModel.Pane.meetings)
            Label("已完成", systemImage: "checkmark.circle")
                .badge(store.doneItems.count)
                .tag(MainModel.Pane.done)
            Label("问答", systemImage: "text.bubble")
                .tag(MainModel.Pane.chat)
                .help("新对话")

            if let id = recorder.meetingID, let start = recorder.startedAt {
                Section("正在录音") {
                    Button {
                        model.pane = .meetings
                        model.selection = id
                    } label: {
                        HStack(spacing: 8) {
                            PulsingDot()
                            Text("会议录音")
                            Spacer()
                            TimelineView(.periodic(from: start, by: 1)) { ctx in
                                Text(DueFormatter.duration(ctx.date.timeIntervalSince(start)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            MailSidebarSection(model: model, mail: mail)
            ConnectionsSidebarSection(model: model, github: github, wecom: wecom)

            ChatSidebarSection(model: model, library: agent.library, session: agent.session)
        }
        .listStyle(.sidebar)
        // Outside the List so its edges can match the rows' selection highlight exactly.
        .safeAreaInset(edge: .top, spacing: 0) {
            BrandHeader(openCount: store.openItems.count,
                        urgentCount: store.openItems.filter { $0.priority == .high || Style.isUrgent($0.dueAt) }.count,
                        nextEvent: calendar.upcoming.min { $0.start < $1.start },
                        onOpenEvent: { model.pane = .calendar; model.selection = nil })
                .padding(.horizontal, BrandHeader.rowInset)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
    }
}

/// Reminders-style circle, drawn with SF Symbols.
private struct CircleCheck: View {
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
                .foregroundStyle(done ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(done ? "恢复为待办" : "完成")
    }
}

// MARK: - To-do list

private struct TodoListColumn: View {
    @ObservedObject var model: MainModel
    @ObservedObject var store: TodoStore
    @ObservedObject var meetings: MeetingStore
    @State private var flipping: Set<UUID> = []

    private var isDone: Bool { model.pane == .done }

    private var q: String { model.query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var filtered: [TodoItem] {
        let base = isDone ? store.doneItems : store.openItems
        guard !q.isEmpty else { return base }
        return base.filter { item in
            [item.title, item.requester, item.source, item.evidence, item.notes]
                .compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
    }

    /// Open: by deadline, then undated ones under their meeting. Done: by when they were finished.
    private var groups: [TodoGroup] {
        if isDone {
            let grouped = Dictionary(grouping: filtered) { DueFormatter.bucket($0.completedAt ?? $0.updatedAt) }
            return DueFormatter.pastBucketOrder.compactMap { key in
                grouped[key].map { TodoGroup(kind: .undated, title: key, items: $0) }
            }
        }
        return TodoGrouping.groups(filtered, meetings: meetings.groupingInfo)
    }

    var body: some View {
        List(selection: $model.selection) {
            ForEach(groups, id: \.key) { group in
                Section {
                    ForEach(group.items) { item in
                        TodoListRow(item: item, checked: (item.status == .done) != flipping.contains(item.id)) {
                            flip(item)
                        }
                        .tag(item.id)
                        .contextMenu { menu(item) }
                    }
                } header: {
                    header(group)
                }
            }
        }
        .listStyle(.inset)
        .animation(.default, value: filtered.map(\.id))
        .overlay {
            if filtered.isEmpty {
                if !q.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else if isDone {
                    ContentUnavailableView("还没有完成的事", systemImage: "clock.arrow.circlepath",
                                           description: Text("完成的待办会保留在这里"))
                } else {
                    ContentUnavailableView("没有待办", systemImage: "checkmark.circle",
                                           description: Text("按 \(HotkeyManager.shared.current.display) 截屏分析，或按 ⌘N 新建"))
                }
            }
        }
    }

    /// A meeting's heading names it and opens it.
    @ViewBuilder private func header(_ group: TodoGroup) -> some View {
        if let id = group.meetingID {
            Button {
                model.query = ""
                model.pane = .meetings
                model.selection = id
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                    Text(group.title).lineLimit(1)
                    if let date = group.date {
                        Text(DueFormatter.stamp(date)).fontWeight(.regular).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("查看这场会议")
        } else {
            Text(group.title)
        }
    }

    @ViewBuilder private func menu(_ item: TodoItem) -> some View {
        Button(item.status == .done ? "恢复为待办" : "完成") { flip(item) }
        if item.status == .open {
            Button(item.pinned == true ? "取消置顶" : "置顶") { store.setPinned(item.id, item.pinned != true) }
            Picker("优先级", selection: Binding(
                get: { item.priority },
                set: { p in store.update(item.id) { $0.priority = p } }
            )) {
                ForEach(TodoPriority.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
        Divider()
        Button("删除", role: .destructive) {
            if model.selection == item.id { model.selection = nil }
            store.delete(item.id)
        }
    }

    /// Let the check land, then move it to the other list.
    private func flip(_ item: TodoItem) {
        guard !flipping.contains(item.id) else { return }
        let completing = item.status == .open
        _ = flipping.insert(item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + (completing ? 0.45 : 0.25)) {
            withAnimation {
                store.setDone(item.id, completing)
                flipping.remove(item.id)
            }
        }
    }
}

private struct TodoListRow: View {
    let item: TodoItem
    let checked: Bool
    let onCheck: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CircleCheck(done: checked, action: onCheck)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(2)
                    .foregroundStyle(checked ? .secondary : .primary)
                meta
            }
            Spacer(minLength: 0)
            if item.pinned == true, item.status == .open {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var meta: some View {
        let who = item.requester.flatMap { $0.isEmpty ? nil : $0 }
        if item.status == .done {
            Text(["完成于 " + DueFormatter.stamp(item.completedAt ?? item.updatedAt), who].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            let due = DueFormatter.string(item.dueAt) ?? item.dueText
            if due != nil || who != nil || item.priority == .high {
                HStack(spacing: 4) {
                    if item.priority == .high {
                        Image(systemName: "exclamationmark").fontWeight(.bold).foregroundStyle(.orange)
                    }
                    if let due {
                        Text(due).foregroundStyle(Style.isUrgent(item.dueAt) ? Style.due(item.dueAt) : .secondary)
                    }
                    if due != nil, who != nil { Text("·") }
                    if let who { Text(who).lineLimit(1) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - To-do detail

private struct TodoDetail: View {
    let item: TodoItem
    @ObservedObject var model: MainModel
    @ObservedObject var store: TodoStore
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var calendar: CalendarCenter

    @State private var title = ""
    @State private var requester = ""
    @State private var scheduledEvent: String?
    @State private var calendarError: String?
    @State private var notes = ""
    @State private var loaded = false
    @State private var confirmDelete = false

    private var isDone: Bool { item.status == .done }

    var body: some View {
        Form {
            Section {
                TextField("标题", text: $title, prompt: Text("标题"), axis: .vertical)
                    .labelsHidden()
                    .onChange(of: title) {
                        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if loaded, !t.isEmpty { store.update(item.id) { $0.title = t } }
                    }
            }

            Section {
                LabeledContent("截止") {
                    DueMenu(due: item.dueAt) { d in store.update(item.id) { $0.dueAt = d } }
                }
                if let text = item.dueText, !text.isEmpty {
                    LabeledContent("原话", value: text)
                }
                Picker("优先级", selection: Binding(
                    get: { item.priority },
                    set: { p in store.update(item.id) { $0.priority = p } }
                )) {
                    ForEach(TodoPriority.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if !isDone {
                    Toggle("置顶", isOn: Binding(
                        get: { item.pinned == true },
                        set: { store.setPinned(item.id, $0) }
                    ))
                }
            }

            Section {
                TextField("谁提的", text: $requester, prompt: Text("无"))
                    .onChange(of: requester) {
                        let r = requester.trimmingCharacters(in: .whitespacesAndNewlines)
                        if loaded { store.update(item.id) { $0.requester = r.isEmpty ? nil : r } }
                    }
                LabeledContent("来源") { source }
                LabeledContent("记录于", value: DueFormatter.long(item.createdAt))
                if let done = item.completedAt {
                    LabeledContent("完成于", value: DueFormatter.long(done))
                }
            }

            if let tip = item.suggestion, !tip.isEmpty, item.status == .open {
                Section {
                    Label {
                        Text(tip).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(AistBrand.gradient)
                    }
                } header: {
                    Text("AI 建议")
                }
            }

            if let evidence = item.evidence, !evidence.isEmpty {
                Section(item.origin == .meeting ? "会上的原话" : item.origin == .email ? "邮件原文" : item.origin == .github ? "GitHub" : "屏幕上的原文") {
                    Text(evidence)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("备注") {
                TextField("备注", text: $notes, prompt: Text("补充信息、链接、进展…"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(3...20)
                    .onChange(of: notes) { if loaded { store.setNotes(item.id, notes) } }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                Button { withAnimation { store.setDone(item.id, !isDone) } } label: {
                    Label(isDone ? "恢复为待办" : "完成", systemImage: isDone ? "arrow.uturn.backward.circle" : "checkmark.circle")
                }
                .help(isDone ? "恢复为待办" : "标记完成")
                Button { Task { await addToCalendar() } } label: {
                    Label(scheduledEvent == nil ? "加入日历" : "在日历中查看",
                          systemImage: scheduledEvent == nil ? "calendar.badge.plus" : "calendar")
                }
                .help(scheduledEvent == nil ? "在日历里为它留出一小时" : "在日历中查看")
                .disabled(isDone)
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("删除", systemImage: "trash")
                }
                .help("删除待办")
            }
        }
        .onAppear {
            title = item.title
            requester = item.requester ?? ""
            notes = item.notes ?? ""
            DispatchQueue.main.async { loaded = true }
        }
        .confirmationDialog("删除「\(item.title)」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                model.selection = nil
                store.delete(item.id)
            }
        } message: {
            Text("删除后无法恢复。")
        }
        .alert("没能加入日历", isPresented: Binding(get: { calendarError != nil }, set: { if !$0 { calendarError = nil } })) {
            Button("好") {}
        } message: {
            Text(calendarError ?? "")
        }
    }

    /// Blocks an hour before the deadline (or tomorrow 10:00); a second click shows it in Calendar.
    private func addToCalendar() async {
        if let id = scheduledEvent {
            if let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") { NSWorkspace.shared.open(url) }
            return
        }
        if !calendar.authorized { await calendar.requestAccess() }
        guard calendar.authorized else {
            calendarError = "Aist 没有日历权限。请到 系统设置 › 隐私与安全性 › 日历 中允许。"
            return
        }
        do {
            scheduledEvent = try calendar.schedule(item)
        } catch {
            calendarError = error.localizedDescription
        }
    }

    @ViewBuilder private var source: some View {
        if let mid = item.meetingID, let meeting = meetings.meeting(mid) {
            SourceLink(symbol: "waveform", text: meeting.title) {
                model.pane = .meetings
                model.selection = mid
            }
        } else if item.meetingID != nil {
            Text("会议（已删除）").foregroundStyle(.secondary)
        } else if let ref = item.emailRef {
            SourceLink(symbol: "envelope", text: Self.cleanSubject(ref.subject)) {
                model.pane = .mail(ref.accountID, ref.mailbox)
                model.mailSelection = "\(ref.mailbox)\u{1}\(ref.uid)"
            }
        } else if let link = item.link, let url = URL(string: link) {
            SourceLink(symbol: item.origin == .github ? "arrow.triangle.pull" : "link", text: item.source ?? link) {
                NSWorkspace.shared.open(url)
            }
        } else if item.origin == .manual {
            Text(item.source ?? "手动添加").foregroundStyle(.secondary)
        } else {
            Label(item.source?.isEmpty == false ? item.source! : "截屏", systemImage: "text.viewfinder")
                .foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// "Fwd: Re: 主题" → "主题"; the full subject stays in the tooltip.
    static func cleanSubject(_ subject: String?) -> String {
        var s = (subject ?? "").trimmingCharacters(in: .whitespaces)
        while let r = s.range(of: #"^(?i)(re|fw|fwd|回复|转发)\s*[:：]\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.isEmpty ? "（无主题）" : s
    }
}

/// One line: icon · truncated title · ↗, clickable — long email subjects no longer wrap across the form.
private struct SourceLink: View {
    let symbol: String
    let text: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(hovering ? Color.accentColor : .primary)
                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help(text)
        .onHover { hovering = $0 }
        .frame(maxWidth: 360, alignment: .trailing)
    }
}

/// Deadline as a pull-down of common choices, like Mail's "Remind Me"; the full calendar only on "自定义…".
private struct DueMenu: View {
    let due: Date?
    let onChange: (Date?) -> Void
    @State private var picking = false
    @State private var draft = Date.now

    var body: some View {
        Menu {
            Button("今天 18:00") { onChange(Self.at(day: 0, hour: 18)) }
            Button("明天 09:00") { onChange(Self.at(day: 1, hour: 9)) }
            Button("明天 18:00") { onChange(Self.at(day: 1, hour: 18)) }
            Button("下周一 09:00") { onChange(Self.nextMonday) }
            Divider()
            Button("自定义…") {
                draft = due ?? Self.at(day: 1, hour: 18)
                picking = true
            }
            if due != nil {
                Divider()
                Button("移除截止时间", role: .destructive) { onChange(nil) }
            }
        } label: {
            Text(due.map(DueFormatter.long) ?? "无")
                .foregroundStyle(Style.due(due))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                CalendarPicker(date: $draft)
                Divider()
                HStack {
                    Text("时间")
                    Spacer()
                    DatePicker("时间", selection: $draft, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .fixedSize()
                }
            }
            .padding(14)
            .fixedSize()
            // Like the system's own popovers: changes apply as you make them.
            .onChange(of: draft) { onChange(draft) }
        }
    }

    private static func at(day: Int, hour: Int) -> Date {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: .now))!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: d)!
    }

    private static var nextMonday: Date {
        let cal = Calendar.current
        let next = cal.nextDate(after: .now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: next)!
    }
}

/// The system month calendar (NSDatePicker), drawn the way Calendar.app shows it:
/// no bezel, no background, no focus ring. Picking a day keeps the time of day.
private struct CalendarPicker: NSViewRepresentable {
    @Binding var date: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.focusRingType = .none
        picker.dateValue = date
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if !Calendar.current.isDate(picker.dateValue, inSameDayAs: date) { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: CalendarPicker
        init(_ parent: CalendarPicker) { self.parent = parent }

        @MainActor @objc func changed(_ sender: NSDatePicker) {
            let cal = Calendar.current
            let time = cal.dateComponents([.hour, .minute], from: parent.date)
            var day = cal.dateComponents([.year, .month, .day], from: sender.dateValue)
            day.hour = time.hour
            day.minute = time.minute
            if let merged = cal.date(from: day) { parent.date = merged }
        }
    }
}

// MARK: - Meeting list

private struct MeetingListColumn: View {
    @ObservedObject var model: MainModel
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var player: AudioPlayback
    let actions: MainActions
    @State private var pendingDelete: [Meeting] = []

    private var q: String { model.query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var failed: [Meeting] { meetings.sorted.filter { $0.status == .failed } }

    private var filtered: [Meeting] {
        let all = meetings.sorted
        guard !q.isEmpty else { return all }
        return all.filter { m in
            var fields = [m.title, m.summary?.overview ?? "", m.notes ?? ""]
            fields += m.summary?.discussionText ?? []
            fields += m.transcript?.map(\.text) ?? []
            // A name finds the meetings where recognition misheard it, and the other way round.
            for t in m.summary?.terms ?? [] { fields.append(([t.name] + t.heard).joined(separator: " ")) }
            return fields.contains { $0.lowercased().contains(q) }
        }
    }

    private var groups: [(String, [Meeting])] {
        let grouped = Dictionary(grouping: filtered) { DueFormatter.bucket($0.startedAt) }
        return DueFormatter.pastBucketOrder.compactMap { key in grouped[key].map { (key, $0) } }
    }

    var body: some View {
        List(selection: $model.selection) {
            ForEach(groups, id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { m in
                        MeetingListRow(meeting: m)
                            .tag(m.id)
                            .contextMenu {
                                if m.status == .ready || m.status == .failed {
                                    Button("重新分析整理") { actions.retryMeeting(m.id) }
                                }
                                Divider()
                                Button("删除…", role: .destructive) { pendingDelete = [m] }
                                    .disabled(m.status == .recording)
                                if m.status == .failed, failed.count > 1 {
                                    Button("删除全部 \(failed.count) 个处理失败的会议…", role: .destructive) {
                                        pendingDelete = failed
                                    }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            if let id = model.selection, let m = meetings.meeting(id), m.status != .recording { pendingDelete = [m] }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }
        )) {
            Button(pendingDelete.count > 1 ? "删除 \(pendingDelete.count) 个会议和录音" : "删除会议和录音",
                   role: .destructive) { delete(pendingDelete) }
        } message: {
            Text("纪要和转写会删除，原始录音移到废纸篓（还能找回）；它生成的待办会保留。")
        }
        .animation(.default, value: filtered.map(\.id))
        .overlay {
            if filtered.isEmpty {
                if !q.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    ContentUnavailableView {
                        Label("没有会议", systemImage: "waveform")
                    } description: {
                        Text("录下你和对方的声音，在本机转写，\n自动生成纪要和你的待办。")
                    } actions: {
                        if !recorder.isRecording {
                            Button("开始会议录音", action: actions.startMeeting)
                        }
                    }
                }
            }
        }
    }
}

extension MeetingListColumn {
    private var deleteTitle: String {
        pendingDelete.count == 1 ? "删除「\(pendingDelete[0].title)」？" : "删除 \(pendingDelete.count) 个处理失败的会议？"
    }

    private func delete(_ list: [Meeting]) {
        for m in list where m.status != .recording {
            if let rec = m.recording, player.loadedID == rec.id { player.stop() }
            if model.selection == m.id { model.selection = nil }
            meetings.delete(m.id)
        }
        pendingDelete = []
    }
}

private struct MeetingListRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(meeting.title).lineLimit(1)
                Spacer(minLength: 0)
                switch meeting.status {
                case .recording: PulsingDot(size: 7)
                case .transcribing, .summarizing: ProgressView().controlSize(.mini)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                case .ready: EmptyView()
                }
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let overview = meeting.summary?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [DueFormatter.stamp(meeting.startedAt)]
        if meeting.duration > 0 { parts.append(DueFormatter.minutes(meeting.duration)) }
        switch meeting.status {
        case .recording: parts.append("录音中")
        case .transcribing: parts.append("转写中…")
        case .summarizing: parts.append("生成纪要中…")
        case .failed: parts.append("处理失败")
        case .ready:
            if let n = meeting.todoIDs?.count, n > 0 { parts.append("\(n) 项待办") }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Meeting detail

/// The original audio, with a scrubber: the transcript can be checked against what was really said.
private struct RecordingPlayer: View {
    let recording: TodoRecording
    @ObservedObject var player: AudioPlayback
    @State private var scrub: Double?

    private var loaded: Bool { player.loadedID == recording.id }
    private var playing: Bool { loaded && player.isPlaying }
    private var total: TimeInterval { loaded ? player.duration : recording.duration }
    private var position: TimeInterval { scrub ?? (loaded ? player.position : 0) }

    var body: some View {
        LabeledContent("原始录音") {
            HStack(spacing: 10) {
                Button { player.toggle(recording) } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .help(playing ? "暂停" : "播放")
                Slider(value: Binding(get: { position }, set: { scrub = $0 }),
                       in: 0 ... max(total, 1)) { editing in
                    if !editing, let t = scrub {
                        player.seek(recording, to: t)
                        scrub = nil
                    }
                }
                .controlSize(.small)
                .frame(minWidth: 120)
                Text("\(DueFormatter.duration(position)) / \(DueFormatter.duration(total))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([TodoStore.folder(for: recording.id)])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("在访达中显示录音文件（mic.m4a 是你，system.m4a 是对方）")
            }
        }
    }
}

private struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject var model: MainModel
    @ObservedObject var store: TodoStore
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var player: AudioPlayback
    let actions: MainActions

    @State private var title = ""
    @State private var notes = ""
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var showTranscript = false
    /// Also list the microphone lines judged to be the other side through the speakers.
    @State private var showEchoes = false
    /// The voice being given a typed name, and the name so far.
    @State private var naming: String?
    @State private var typedName = ""
    /// A transcript line to bring into view (from a key point's / to-do's time).
    @State private var jumpTarget: Int?
    /// An earlier version of the minutes being read; nil shows the current ones.
    @State private var versionID: UUID?
    @State private var confirmDeleteVersion = false

    /// The meeting with the minutes being read: the current ones, or the earlier version picked.
    private var shown: Meeting { meeting.showing(version: versionID) }

    /// `version`: an earlier version of the minutes to open on. `transcript`: with the transcript open.
    init(meeting: Meeting, model: MainModel, store: TodoStore, meetings: MeetingStore, recorder: AudioRecorder,
         player: AudioPlayback, actions: MainActions, version: UUID? = nil, transcript: Bool = false) {
        self.meeting = meeting
        self.model = model
        self.store = store
        self.meetings = meetings
        self.recorder = recorder
        self.player = player
        self.actions = actions
        _versionID = State(initialValue: version)
        _showTranscript = State(initialValue: transcript)
    }

    private var canRegenerate: Bool { meeting.recording != nil && (meeting.status == .ready || meeting.status == .failed) }

    private var myTodos: [TodoItem] {
        (meeting.todoIDs ?? []).compactMap { id in store.items.first { $0.id == id } }
    }

    /// The transcript as listed: what was spoken, or every line with the echoes shown.
    private var lines: [TranscriptSegment] {
        let all = meeting.transcript ?? []
        return showEchoes ? all : all.spoken
    }

    private var echoCount: Int { (meeting.transcript ?? []).filter { $0.echo == true }.count }

    /// The transcript line said closest before `t`.
    private func lineIndex(at t: Double) -> Int? {
        let segs = lines
        guard !segs.isEmpty else { return nil }
        return segs.lastIndex { $0.start <= t + 1 } ?? 0
    }

    /// Opens the transcript at the line said at `t` and plays the recording from there.
    private func jump(to t: Double) {
        showTranscript = true
        jumpTarget = lineIndex(at: t)
        if let rec = meeting.recording { player.play(rec, from: max(0, t - 0.5)) }
    }

    @ViewBuilder private func timeChip(_ t: Double?) -> some View {
        if let t, meeting.transcript?.isEmpty == false {
            Button { jump(to: t) } label: {
                Label(DueFormatter.duration(t), systemImage: "text.quote")
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("跳到转写里的原话并播放")
        }
    }

    private var exportTodos: [MeetingExport.Todo] {
        myTodos.map { MeetingExport.Todo(title: $0.title, due: DueFormatter.string($0.dueAt) ?? $0.dueText, done: $0.status == .done) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: jumpTarget) {
                    guard let i = jumpTarget else { return }
                    // After the disclosure group has opened.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation { proxy.scrollTo("seg\(i)", anchor: .center) }
                        jumpTarget = nil
                    }
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("标题", text: $title, prompt: Text("会议标题"), axis: .vertical)
                    .labelsHidden()
                    .onChange(of: title) {
                        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard loaded, !t.isEmpty, t != meeting.title else { return }
                        meetings.update(meeting.id) {
                            $0.title = t
                            $0.titleEdited = true
                        }
                    }
                LabeledContent("时间", value: DueFormatter.long(meeting.startedAt))
                if meeting.duration > 0 {
                    LabeledContent("时长", value: DueFormatter.minutes(meeting.duration))
                }
                if let people = meeting.attendees, !people.isEmpty {
                    LabeledContent("参会人", value: people.joined(separator: "、"))
                }
                if let rec = meeting.recording {
                    RecordingPlayer(recording: rec, player: player)
                }
                versions
            }

            status

            if let s = shown.summary {
                if !s.overview.isEmpty {
                    Section("概要") {
                        Text(s.overview).textSelection(.enabled)
                    }
                }
                todoSection(s)
                if let topics = s.topics, !topics.isEmpty {
                    topicSections(topics)
                } else {
                    // Minutes from before topics.
                    bullets("要点", s.keyPoints, time: s.keyPointTime)
                }
                bullets("决定", s.decisions, time: s.decisionTime)
                bullets("待跟进", s.openQuestions)
                speakerSection(s)
                termSection(s)
            }

            if meeting.transcript?.isEmpty == false {
                Section {
                    DisclosureGroup("转写全文（\(lines.count) 段）", isExpanded: $showTranscript) {
                        let who = SpeakerLabels.labels(lines, voices: meeting.voices)
                        // Names need more room than 我 / 对方.
                        let width: CGFloat = meeting.voices == nil ? 32 : 68
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, seg in
                            let current = isCurrent(seg)
                            let echo = seg.echo == true
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(echo ? "回声" : who[i])
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .foregroundStyle(echo ? AnyShapeStyle(.tertiary)
                                        : (who[i] == "我" ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)))
                                    .frame(width: width, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(seg.text).textSelection(.enabled)
                                        .foregroundStyle(echo ? .secondary : .primary)
                                    if let tr = seg.translation, !tr.isEmpty {
                                        Text(tr).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 8)
                                if let rec = meeting.recording {
                                    // Jump to this line to hear what was actually said.
                                    Button { player.play(rec, from: max(0, seg.start - 0.5)) } label: {
                                        Label(DueFormatter.duration(seg.start), systemImage: current ? "speaker.wave.2.fill" : "play.circle")
                                            .monospacedDigit()
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(current ? Color.accentColor : .secondary)
                                    .help("从这里播放原始录音")
                                } else {
                                    Text(DueFormatter.duration(seg.start))
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .listRowBackground(current ? Color.accentColor.opacity(0.08) : nil)
                            .id("seg\(i)")
                        }
                    }
                } footer: {
                    if echoCount > 0 {
                        HStack(alignment: .firstTextBaseline) {
                            Text(showEchoes ? "标为「回声」的行是麦克风从扬声器收到的对方声音，不计入纪要和导出。"
                                            : "已隐藏 \(echoCount) 行回声：麦克风从扬声器收到的对方声音。")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(showEchoes ? "隐藏回声" : "显示回声") { showEchoes.toggle() }
                                .buttonStyle(.link)
                        }
                    }
                }
            }

            Section {
                TextField("备注", text: $notes, prompt: Text("背景、参会人、要特别关注的点…"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(3...20)
                    .onChange(of: notes) {
                        guard loaded else { return }
                        let value = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
                        meetings.update(meeting.id) { $0.notes = value }
                    }
            } header: {
                Text("备注")
            } footer: {
                Text("重新分析整理时 AI 会参考备注。").foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                Button { actions.emailMinutes(meeting.id, versionID) } label: {
                    Label("发送纪要", systemImage: "envelope")
                }
                .help("把纪要和双方的待办写成邮件，收件人默认是参会人")
                .disabled(shown.summary == nil)
                Menu {
                    // One click: the usual destination is a doc or chat, so straight to the clipboard.
                    Button("拷贝为 Markdown") { copyMarkdown() }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    Divider()
                    Button("Markdown…") { export(.markdown) }
                    Button("Word 文档…") { export(.word) }
                    Button("字幕（SRT）…") { export(.srt) }
                        .disabled(meeting.transcript?.isEmpty != false)
                } label: {
                    Label(copied ? "已拷贝" : "导出", systemImage: copied ? "checkmark" : "square.and.arrow.up")
                }
                .help("导出纪要和转写")
                .disabled(shown.summary == nil && meeting.transcript?.isEmpty != false)
                Button { actions.retryMeeting(meeting.id) } label: {
                    Label(meeting.status == .failed ? "重试" : "重新分析整理", systemImage: "arrow.clockwise")
                }
                .help(meeting.status == .failed ? "重试" : "重新整理这场会议的纪要；现在的纪要会留在「纪要版本」里")
                .disabled(!canRegenerate)
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("删除", systemImage: "trash")
                }
                .help("删除会议")
                .disabled(meeting.status == .recording)
            }
        }
        .onAppear {
            title = meeting.title
            notes = meeting.notes ?? ""
            DispatchQueue.main.async { loaded = true }
        }
        .onChange(of: meeting.title) { if meeting.title != title { title = meeting.title } }
        // New minutes arrived, or the version being read is gone: back to the current ones.
        .onChange(of: meeting.summaryCreatedAt) { versionID = nil }
        .onChange(of: meeting.summaryHistory) {
            if let id = versionID, meeting.summaryHistory?.contains(where: { $0.id == id }) != true { versionID = nil }
        }
        .alert("这个声音是谁？", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("名字", text: $typedName)
            Button("好") {
                let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = naming, !name.isEmpty { setName(name, for: id) }
                naming = nil
            }
            Button("取消", role: .cancel) { naming = nil }
        }
        .confirmationDialog("删除这个版本的纪要？", isPresented: $confirmDeleteVersion) {
            Button("删除此版本", role: .destructive) {
                guard let id = versionID else { return }
                versionID = nil
                meetings.update(meeting.id) { $0.deleteSummaryVersion(id) }
            }
        } message: {
            Text("只删除这一版纪要，会议、录音、转写和其他版本都不受影响。删除后无法恢复。")
        }
        .confirmationDialog("删除「\(meeting.title)」？", isPresented: $confirmDelete) {
            Button("删除会议和录音", role: .destructive) {
                if let rec = meeting.recording, player.loadedID == rec.id { player.stop() }
                model.selection = nil
                meetings.delete(meeting.id)
            }
        } message: {
            Text("纪要和转写会删除，原始录音移到废纸篓（还能找回）；它生成的待办会保留。")
        }
    }

    private func isCurrent(_ seg: TranscriptSegment) -> Bool {
        guard let rec = meeting.recording, player.loadedID == rec.id, player.isPlaying else { return false }
        return seg.start <= player.position && player.position < max(seg.end, seg.start + 1)
    }

    @ViewBuilder private var status: some View {
        switch meeting.status {
        case .recording:
            Section {
                HStack {
                    PulsingDot()
                    Text(LiveTranscript.isSupported ? "正在录音和实时转写，结束后生成完整纪要" : "正在录音，结束后自动转写并生成纪要")
                    Spacer()
                    if recorder.meetingID == meeting.id {
                        Button("会议实况", action: actions.showLive)
                        Button("结束录音", action: actions.stopMeeting)
                    }
                }
            }
            if recorder.meetingID == meeting.id, LiveTranscript.isSupported {
                Section("速记") {
                    LiveNotesView(session: recorder.session, live: recorder.live)
                        .frame(minHeight: 120, maxHeight: 360)
                }
                Section("实时转写") {
                    LiveTranscriptList(live: recorder.live, compact: true)
                        .frame(height: 320)
                }
            }
        case .transcribing, .summarizing:
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(meeting.status == .transcribing
                         ? (MeetingSettings.afterModel != nil ? "正在用 AstraFlow 转写录音…" : "正在本机转写录音…")
                         : "正在分析录音，生成纪要和待办…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed:
            Section {
                Label(meeting.error ?? "处理失败", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        case .ready:
            if meeting.summary == nil {
                Section { Text("这场会议没有生成纪要。").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Minutes

    /// Earlier versions of the minutes, once "重新分析整理" has replaced some.
    @ViewBuilder private var versions: some View {
        if let history = meeting.summaryHistory, !history.isEmpty {
            Picker("纪要版本", selection: $versionID) {
                Text("当前 · " + DueFormatter.stamp(meeting.summaryCreatedAt ?? meeting.startedAt)).tag(UUID?.none)
                ForEach(history.reversed()) { v in
                    // Minutes from before versions were kept carry no date of their own.
                    Text(v.createdAt == meeting.startedAt ? "最初的版本" : DueFormatter.stamp(v.createdAt)).tag(UUID?.some(v.id))
                }
            }
            if let id = versionID {
                HStack {
                    Text("正在看较早的一版纪要。").foregroundStyle(.secondary)
                    Spacer()
                    Button("设为当前") {
                        versionID = nil
                        meetings.update(meeting.id) { $0.restoreSummary(id) }
                    }
                    Button("删除此版本…", role: .destructive) { confirmDeleteVersion = true }
                }
            }
        }
    }

    /// Everyone's to-dos: the user's own (real to-dos, tickable) first, then what fell to others.
    @ViewBuilder private func todoSection(_ s: MeetingSummary) -> some View {
        if !myTodos.isEmpty || !s.othersActions.isEmpty {
            Section("待办") {
                ForEach(myTodos) { todo in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CircleCheck(done: todo.status == .done) {
                            withAnimation { store.setDone(todo.id, todo.status == .open) }
                        }
                        Button {
                            model.pane = todo.status == .done ? .done : .todos
                            model.selection = todo.id
                        } label: {
                            Text(todo.title).foregroundStyle(todo.status == .done ? .secondary : .primary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if let due = DueFormatter.string(todo.dueAt) ?? todo.dueText {
                            Text(due).foregroundStyle(.secondary)
                        }
                        timeChip(meeting.transcript.flatMap { MeetingTime.find(todo.evidence, in: $0)?.start })
                    }
                }
                ForEach(Array(s.othersActions.enumerated()), id: \.offset) { _, a in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Someone else's: nothing to tick.
                        Image(systemName: "person.circle")
                            .imageScale(.large)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.task).textSelection(.enabled)
                            Text(a.who ?? "待定").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let due = a.dueText { Text(due).foregroundStyle(.secondary) }
                        timeChip(a.time)
                    }
                }
            }
        }
    }

    /// The discussion, one section per topic in the order it came up.
    private func topicSections(_ topics: [MeetingTopic]) -> some View {
        ForEach(Array(topics.enumerated()), id: \.offset) { i, topic in
            Section {
                ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline) {
                        Text(point.text).textSelection(.enabled)
                        Spacer()
                        timeChip(point.time)
                    }
                }
                if let end = topic.conclusion {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("结论").fontWeight(.medium)
                        Text(end).textSelection(.enabled)
                        Spacer()
                    }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("议题 \(i + 1) · \(topic.title)")
                    Spacer()
                    timeChip(topic.time)
                }
            }
        }
    }

    // MARK: Voices

    /// The people whose voices were told apart, in the order first heard.
    private var people: [MeetingVoice] {
        (meeting.voices ?? []).filter(\.isPerson).sorted { ($0.firstAt, $0.id) < ($1.firstAt, $1.id) }
    }

    private func changeVoice(_ id: String, _ change: (inout MeetingVoice) -> Void) {
        meetings.update(meeting.id) { m in
            guard let i = m.voices?.firstIndex(where: { $0.id == id }) else { return }
            change(&m.voices![i])
        }
    }

    /// The user says who a voice is (nil: nobody known). What the user says about a voice survives
    /// every re-analysis.
    private func setName(_ name: String?, for id: String) {
        changeVoice(id) {
            $0.name = name
            $0.isMe = nil
            $0.nameSource = name == nil ? nil : "user"
            $0.certain = name == nil ? nil : true
        }
        // A name the user confirmed is worth remembering the voice by.
        if let name, MeetingSettings.rememberVoices, let rec = meeting.recording {
            let folder = TodoStore.folder(for: rec.id), offset = rec.micOffset ?? 0
            Task.detached { SpeakerPass.learn(voice: id, name: name, folder: folder, micOffset: offset) }
        }
    }

    /// The user says a voice is their own: it reads as 我, and is kept to recognize them later.
    private func setMe(_ id: String) {
        meetings.update(meeting.id) { m in
            for i in (m.voices ?? []).indices {
                if m.voices![i].id == id {
                    m.voices![i].isMe = true
                    m.voices![i].name = nil
                    m.voices![i].nameSource = "user"
                    m.voices![i].certain = true
                } else if m.voices![i].isMe == true {
                    m.voices![i].isMe = nil
                }
            }
        }
        if MeetingSettings.rememberVoices, let rec = meeting.recording {
            let folder = TodoStore.folder(for: rec.id), offset = rec.micOffset ?? 0
            Task.detached { SpeakerPass.learnMe(voice: id, folder: folder, micOffset: offset) }
        }
    }

    /// The model's one line about a voice, from the minutes being read.
    private func said(_ voice: MeetingVoice, in s: MeetingSummary) -> String? {
        s.speakers?.first { $0.voice == voice.id }?.said
    }

    @ViewBuilder private func voiceSection(_ s: MeetingSummary) -> some View {
        let people = people
        let letters = SpeakerLabels.letters(meeting.voices ?? [])
        // Names from the invitation nobody carries yet.
        let free = (meeting.attendees ?? []).filter { name in !people.contains { $0.name == name } }
        Section {
            ForEach(people) { voice in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(SpeakerLabels.label(voice, letters: letters)).fontWeight(.medium)
                    if voice.nameSource == "voiceprint" {
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                            .help("按声音认出来的：和以前会议里你确认过的声音一致")
                    }
                    if voice.nameSource == "llm", voice.certain != true {
                        Text("推测")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                            .help("AI 根据对话和日程里的参会人推断，不一定准确；可以点转写里的时间听原声核对")
                    }
                    if let said = said(voice, in: s), !said.isEmpty { Text(said).foregroundStyle(.secondary) }
                    Spacer()
                    Text(DueFormatter.minutes(voice.speaking)).foregroundStyle(.tertiary).monospacedDigit()
                    Menu {
                        // A guess the user agrees with becomes theirs.
                        if voice.nameSource != "user", voice.isMe != true, let name = voice.name {
                            Button("确认是\(name)") { setName(name, for: voice.id) }
                            Divider()
                        }
                        Button("我") { setMe(voice.id) }
                        ForEach(free, id: \.self) { name in
                            Button(name) { setName(name, for: voice.id) }
                        }
                        Button("其他名字…") {
                            typedName = voice.name ?? ""
                            naming = voice.id
                        }
                        let others = people.filter { $0.id != voice.id }
                        if !others.isEmpty {
                            Divider()
                            Menu("和…是同一个人") {
                                ForEach(others) { other in
                                    Button(SpeakerLabels.label(other, letters: letters)) {
                                        changeVoice(voice.id) {
                                            $0.sameAs = other.id
                                            $0.nameSource = "user"
                                        }
                                    }
                                }
                            }
                        }
                        if voice.isMe == true || voice.name != nil {
                            Divider()
                            Button("清除名字") { setName(nil, for: voice.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("这个声音是谁")
                }
            }
        } header: {
            Text("发言人")
        } footer: {
            Text("按录音里的声音区分；名字由 AI 结合对话和日程推断，标「推测」的不一定准。改过名字后「重新分析整理」，纪要正文也会用上。")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func speakerSection(_ s: MeetingSummary) -> some View {
        if !people.isEmpty {
            voiceSection(s)
        } else if let speakers = s.speakers, !speakers.isEmpty {
            Section {
                ForEach(Array(speakers.enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(p.name).fontWeight(.medium)
                        if !p.certain {
                            Text("推测")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                                .help("AI 根据参会人和对话内容推断，不一定准确；可以点转写里的时间听原声核对")
                        }
                        Text(p.said).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("发言人")
            } footer: {
                if meeting.calendarEventID != nil {
                    Text("按日程里的参会人推断；转写只区分「我」和「对方」。").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func termSection(_ s: MeetingSummary) -> some View {
        if let terms = s.terms, !terms.isEmpty {
            Section {
                ForEach(terms, id: \.name) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(t.name).fontWeight(.medium)
                            if !t.note.isEmpty { Text(t.note).foregroundStyle(.secondary) }
                        }
                        if !t.heard.isEmpty {
                            Text("转写里听成：\(t.heard.joined(separator: "、"))")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("人名与术语")
            } footer: {
                Text("搜索正确写法也能找到被听错的会议。").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func bullets(_ title: String, _ items: [String], time: ((Int) -> Double?)? = nil) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, text in
                    HStack(alignment: .firstTextBaseline) {
                        Text(text).textSelection(.enabled)
                        Spacer()
                        timeChip(time?(i))
                    }
                }
            }
        }
    }

    // MARK: Export

    private enum ExportKind { case markdown, word, srt }

    private func copyMarkdown() {
        let markdown = MeetingExport.markdown(shown, myTodos: exportTodos, myName: UserIdentity.names.first ?? "我")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func export(_ kind: ExportKind) {
        let panel = NSSavePanel()
        let name = shown.title.replacingOccurrences(of: "/", with: "-")
        let markdown = MeetingExport.markdown(shown, myTodos: exportTodos, myName: UserIdentity.names.first ?? "我")
        let data: Data?
        switch kind {
        case .markdown:
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = name + ".md"
            data = Data(markdown.utf8)
        case .srt:
            panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .plainText]
            panel.nameFieldStringValue = name + ".srt"
            data = Data(MeetingExport.srt(meeting.transcript ?? [], voices: meeting.voices).utf8)
        case .word:
            panel.allowedContentTypes = [.init(filenameExtension: "docx") ?? .data]
            panel.nameFieldStringValue = name + ".docx"
            data = Self.docx(markdown)
        }
        guard let data, panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    /// Word via AppKit's own .docx writer, from the Markdown rendered as rich text.
    private static func docx(_ markdown: String) -> Data? {
        guard let parsed = try? NSAttributedString(
            markdown: markdown,
            options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else { return nil }
        let text = NSMutableAttributedString(attributedString: parsed)
        Self.applyBlockStyles(text)
        return try? text.data(from: NSRange(location: 0, length: text.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    /// Markdown parsing keeps headings and list items as presentation intents, not fonts or line
    /// breaks; turn them into what a Word reader sees.
    private static func applyBlockStyles(_ text: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: text.length)
        var blocks: [(NSRange, PresentationIntent?)] = []
        text.enumerateAttribute(.presentationIntentAttributeName, in: full) { value, range, _ in
            blocks.append((range, value as? PresentationIntent))
        }
        let base = NSFont.systemFont(ofSize: 12)
        for (range, intent) in blocks.reversed() {
            var font = base
            var prefix = ""
            for component in intent?.components ?? [] {
                switch component.kind {
                case let .header(level): font = NSFont.boldSystemFont(ofSize: level == 1 ? 20 : 15)
                case .listItem: prefix = "• "
                case .blockQuote: font = NSFont.systemFont(ofSize: 11)
                default: break
                }
            }
            text.enumerateAttribute(.font, in: range) { value, sub, _ in
                let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                let f = traits.contains(.bold) ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
                text.addAttribute(.font, value: f, range: sub)
            }
            text.insert(NSAttributedString(string: "\n"), at: NSMaxRange(range))
            if !prefix.isEmpty { text.insert(NSAttributedString(string: prefix), at: range.location) }
        }
    }
}

// MARK: - Layout check

/// `-aistMeetingShot <dir>`: draws the meeting detail for an invented meeting into PNGs, off screen,
/// to check the layout. The meeting lives in stores of its own in a temporary folder; nobody's data
/// is read or written.
@MainActor
enum MeetingDetailDemo {
    static func shoot(into dir: String, recorder: AudioRecorder, player: AudioPlayback) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aist-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TodoStore(fileURL: folder.appendingPathComponent("todos.json"))
        let meetings = MeetingStore(fileURL: folder.appendingPathComponent("meetings.json"))
        guard let earlier = try? MeetingSummarizer.parse(earlierMinutes), let current = try? MeetingSummarizer.parse(minutes) else { return }
        let id = meetings.create(startedAt: Date(timeIntervalSince1970: 1_800_000_000)).id
        let todos = store.apply(current.myTodos, origin: .meeting, meetingID: id)
        meetings.update(id) {
            $0.duration = 1500
            $0.status = .ready
            $0.attendees = ["张三", "李四"]
            // One line the microphone only picked up from the speakers.
            var echo = TranscriptSegment(speaker: .me, start: 16.2, end: 23, text: "原定三十号整体上线但测试只剩三天风险比较大")
            echo.echo = true
            var lines = [
                TranscriptSegment(speaker: .others, start: 16, end: 23, text: "原定三十号整体上线，但测试只剩三天，风险比较大。"),
                echo,
                TranscriptSegment(speaker: .me, start: 40, end: 47, text: "我建议分两期，第一期只上订单和支付。"),
                TranscriptSegment(speaker: .others, start: 100, end: 108, text: "第二期多了对账功能，大概多八个人天。"),
                TranscriptSegment(speaker: .others, start: 120, end: 127, text: "折扣我回去问一下财务，周五前给你答复。"),
                TranscriptSegment(speaker: .me, start: 128, end: 135, text: "那我先按十三万二做一版报价单，周四发你。"),
            ]
            // Three voices: one named by the minutes (a guess), one still a letter, the user.
            for (i, voice) in ["s1", "m2", "m1", "s2", "s1", "m1"].enumerated() { lines[i].voice = voice }
            $0.transcript = lines
            var named = MeetingVoice(id: "s1", track: .others, speaking: 540, firstAt: 16)
            named.name = "张三"
            named.nameSource = "llm"
            named.certain = false
            var me = MeetingVoice(id: "m1", track: .me, speaking: 420, firstAt: 40)
            me.isMe = true
            var speakers = MeetingVoice(id: "m2", track: .me, speaking: 500, firstAt: 16.2)
            speakers.echoOf = "s1"
            $0.voices = [named, MeetingVoice(id: "s2", track: .others, speaking: 95, firstAt: 100), me, speakers]
            $0.replaceSummary(earlier.summary, title: earlier.title, at: $0.startedAt.addingTimeInterval(1500))
            $0.replaceSummary(current.summary, title: current.title, at: $0.startedAt.addingTimeInterval(86400))
            $0.todoIDs = todos.added
        }
        guard let meeting = meetings.meeting(id) else { return }
        let actions = MainActions(capture: {}, voice: {}, startMeeting: {}, stopMeeting: {}, retryMeeting: { _ in },
                                  emailMinutes: { _, _ in }, showLive: {}, recordEvent: { _ in })
        for (name, version) in [("meeting-detail", UUID?.none), ("meeting-detail-earlier", meeting.summaryHistory?.first?.id)] {
            let view = MeetingDetail(meeting: meeting, model: MainModel(), store: store, meetings: meetings,
                                     recorder: recorder, player: player, actions: actions, version: version, transcript: true)
            // Tall enough for every section, and far off any screen.
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 720, height: 1900),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1.5))
            if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
            window.close()
        }
    }

    /// Topic-by-topic minutes, as they are written now.
    private static let minutes = """
        {"title": "项目 A 周会", "overview": "周会过了交付排期和报价两件事。原定月底整体上线，因为测试只剩三天改成分两期：三十号先上订单和支付，报表和导出顺延两周。第二期多了对账功能，报价从十二万调到十三万二，折扣等财务答复。",
         "speakers": [{"voice": "s1", "name": "张三", "said": "主持会议，指出测试时间不够，负责向财务确认折扣", "certain": false, "basis": null},
                      {"voice": "s2", "name": "说话人A", "said": "补充了第二期的工作量", "certain": false, "basis": null}],
         "topics": [
           {"title": "交付排期", "at": "00:16", "conclusion": "分两期交付：三十号上订单和支付，十四号上报表和导出。",
            "points": [{"text": "张三说原定三十号整体上线，但测试只剩三天，风险比较大。", "at": "00:16"},
                       {"text": "李四认为三天不够：接口联调上周才完成，回归测试至少要五个工作日。", "at": "00:24"},
                       {"text": "李四建议分两期，第一期只上订单和支付，报表和导出顺延两周。", "at": "00:40"}]},
           {"title": "报价调整", "at": "01:28", "conclusion": null,
            "points": [{"text": "第二期多了对账功能，工作量大概多八个人天，按人天单价一千五算多一万二。", "at": "01:36"},
                       {"text": "李四先按十三万二做一版报价单；要不要给折扣，张三回去问财务。", "at": "02:00"}]}],
         "decisions": ["分两期交付：三十号上订单和支付，十四号上报表和导出"], "decision_at": ["01:20"],
         "open_questions": ["十三万二的报价要不要给折扣，等财务答复"],
         "my_todos": [{"title": "做一版十三万二的报价单发张三", "requester": "张三", "source": null, "due_text": "周四", "due_at": null,
                       "priority": "medium", "evidence": "那我先按十三万二做一版报价单，周四发你。", "details": null, "duplicate_of": null, "suggestion": null}],
         "others_todos": [{"who": "张三", "task": "向财务确认报价折扣", "due_text": "周五前", "at": "02:00"},
                          {"who": null, "task": "写第二期的验收标准", "due_text": null, "at": null}],
         "terms": [{"name": "对账功能", "note": "第二期新增的功能", "heard": ["对帐功能"]}]}
        """

    /// The flat minutes older versions wrote, as the version this meeting had before.
    private static let earlierMinutes = """
        {"title": "项目 A 周会", "overview": "定了分两期交付，报价待定。",
         "key_points": ["测试只剩三天，月底整体上线有风险", "第二期多了对账功能，报价要调整"], "key_point_at": ["00:16", "01:36"],
         "decisions": ["分两期交付"], "decision_at": ["01:20"], "open_questions": ["报价折扣"], "my_todos": [],
         "others_todos": [{"who": "张三", "task": "向财务确认报价折扣", "due_text": "周五前", "at": "02:00"}]}
        """
}

extension TodoPriority {
    var label: String {
        switch self {
        case .high: "高"
        case .medium: "中"
        case .low: "低"
        }
    }
}
