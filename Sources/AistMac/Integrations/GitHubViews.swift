import AistCore
import AppKit
import SwiftUI

// MARK: - Sidebar

/// "连接": outside services that feed aist. GitHub for now; WeCom next.
struct ConnectionsSidebarSection: View {
    @ObservedObject var model: MainModel
    @ObservedObject var github: GitHubCenter
    @ObservedObject var wecom: WeComCenter

    var body: some View {
        Section("连接") {
            WeComSidebarRow(wecom: wecom)
            if github.isConnected {
                Label { Text("GitHub") } icon: { Image.github.resizable().scaledToFit().frame(width: 15, height: 15) }
                    .badge(github.unreadCount)
                    .tag(MainModel.Pane.github)
                    .contextMenu {
                        Button("断开 GitHub", role: .destructive) {
                            if model.pane == .github { model.pane = .todos }
                            github.disconnect()
                        }
                    }
            } else {
                Button { github.connecting = true } label: {
                    Label { Text("连接 GitHub…") } icon: { Image.github.resizable().scaledToFit().frame(width: 15, height: 15) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - List

struct GitHubListColumn: View {
    @ObservedObject var model: MainModel
    @ObservedObject var github: GitHubCenter

    private var q: String { model.query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var filtered: [GHNotification] {
        guard !q.isEmpty else { return github.notifications }
        return github.notifications.filter {
            $0.subject.title.lowercased().contains(q) || $0.repo.lowercased().contains(q)
        }
    }

    private var groups: [(String, [GHNotification])] {
        let actionable = filtered.filter(\.isActionable)
        let rest = filtered.filter { !$0.isActionable }
        return [("需要你处理", actionable), ("其他通知", rest)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        List(selection: $model.githubSelection) {
            if let error = github.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { n in
                        GHRow(notification: n, hasTodo: github.todo(for: n) != nil)
                            .tag(n.id)
                            .contextMenu { menu(n) }
                            .swipeActions(edge: .trailing) {
                                Button { Task { await github.markDone(n) } } label: {
                                    Label("完成", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .leading) {
                                if n.unread {
                                    Button { Task { await github.markRead(n) } } label: {
                                        Label("已读", systemImage: "envelope.open")
                                    }
                                    .tint(.blue)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if filtered.isEmpty, github.error == nil {
                if !q.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else if github.loading {
                    ProgressView()
                } else {
                    ContentUnavailableView("没有未读通知", systemImage: "bell.slash",
                                           description: Text("GitHub 上的新通知会自动出现在这里。"))
                }
            }
        }
        // The poll timer keeps the list fresh; switching to the page only refreshes when it's been a while.
        .task { await github.refreshIfStale() }
    }

    @ViewBuilder private func menu(_ n: GHNotification) -> some View {
        Button("在浏览器中打开") { github.open(n) }
        Button("加入待办") { github.makeTodo(n) }
            .disabled(github.todo(for: n) != nil)
        Divider()
        if n.unread {
            Button("标为已读") { Task { await github.markRead(n) } }
        }
        Button("完成（移出收件箱）") { Task { await github.markDone(n) } }
    }
}

private struct GHRow: View {
    let notification: GHNotification
    let hasTodo: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notification.symbol)
                .foregroundStyle(notification.unread ? Color.accentColor : .secondary)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(notification.repo).lineLimit(1)
                    if let number = notification.number { Text(number) }
                    Spacer(minLength: 4)
                    Text(notification.updated_at, format: .relative(presentation: .named))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(notification.subject.title)
                    .fontWeight(notification.unread ? .semibold : .regular)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(notification.reasonLabel)
                    if hasTodo {
                        Label("已在待办", systemImage: "checklist").labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(notification.isActionable ? Color.orange : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct GitHubDetail: View {
    let notification: GHNotification
    @ObservedObject var model: MainModel
    @ObservedObject var github: GitHubCenter

    private var detail: GHSubjectDetail? { github.details[notification.id] }

    private var stateText: String? {
        guard let d = detail, let state = d.state else { return nil }
        if d.merged { return "已合并" }
        if d.draft { return "草稿" }
        return state == "open" ? "进行中" : "已关闭"
    }

    var body: some View {
        Form {
            Section {
                Text(notification.subject.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                LabeledContent("仓库") {
                    Link(notification.repo, destination: URL(string: notification.repository.html_url)!)
                }
                LabeledContent("类型", value: Self.typeLabel(notification.subject.type) + (notification.number.map { " \($0)" } ?? ""))
                LabeledContent("原因", value: notification.reasonLabel)
                if let stateText { LabeledContent("状态", value: stateText) }
                if let author = detail?.author { LabeledContent("作者", value: author) }
                LabeledContent("更新于", value: DueFormatter.long(notification.updated_at))
            }

            Section("待办") {
                if let todo = github.todo(for: notification) {
                    Button {
                        model.pane = todo.status == .done ? .done : .todos
                        model.selection = todo.id
                    } label: {
                        LabeledContent(todo.title, value: todo.status == .done ? "已完成" : "待办")
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { github.makeTodo(notification) } label: {
                        Label("加入待办", systemImage: "checklist")
                    }
                }
            }

            if let body = detail?.body {
                Section("描述") {
                    Text(body.count > 4000 ? String(body.prefix(4000)) + "…" : body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                Button { github.open(notification) } label: {
                    Label("在浏览器中打开", systemImage: "safari")
                }
                .help("在浏览器中打开")
                Button { Task { await github.markDone(notification) } } label: {
                    Label("完成", systemImage: "checkmark.circle")
                }
                .help("完成（从 GitHub 收件箱移出）")
            }
        }
        .task {
            await github.loadDetail(notification)
            await github.markRead(notification)
        }
    }

    static func typeLabel(_ type: String) -> String {
        switch type {
        case "PullRequest": "Pull Request"
        case "Issue": "Issue"
        case "Release": "发布"
        case "Discussion": "讨论"
        case "Commit": "提交"
        case "CheckSuite", "WorkflowRun": "CI"
        default: type
        }
    }
}

// MARK: - Connect sheet

/// Mail-style "add account" sheet: icon and title on top, the quick way first, a token as the fallback.
struct ConnectGitHubView: View {
    @ObservedObject var github: GitHubCenter
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum CLI: Equatable { case checking, none, expired, ready(token: String, login: String) }

    @State private var cli: CLI = .checking
    @State private var token = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var tokenFocused: Bool

    private static let newTokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=notifications,repo&description=Aist")!

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                ConnectHeader(icon: .github, tint: Color(white: 0.13),
                              title: "连接 GitHub",
                              subtitle: "请你 Review、指派给你的通知会自动成为待办。")

                cliSection

                VStack(alignment: .leading, spacing: 8) {
                    Text("个人访问令牌").font(.headline)
                    SecureField("ghp_…", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($tokenFocused)
                        .onSubmit { if canSubmit { Task { await connect(token) } } }
                    HStack(spacing: 4) {
                        Text("经典令牌（classic），勾选 notifications 和 repo。")
                            .foregroundStyle(.secondary)
                        Link("生成令牌…", destination: Self.newTokenURL)
                    }
                    .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()
            HStack {
                Label("令牌只保存在本机钥匙串", systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("连接") { Task { await connect(token) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.default, value: cli)
        .animation(.default, value: error)
        .task { await checkCLI() }
    }

    private var canSubmit: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty && !working }

    /// "以 <login> 继续" when gh is signed in; a hint when its login has expired; nothing when gh isn't there.
    @ViewBuilder private var cliSection: some View {
        switch cli {
        case .checking:
            ProgressView().controlSize(.small).frame(height: 44)
        case let .ready(t, login):
            VStack(spacing: 6) {
                Button { Task { await connect(t) } } label: {
                    Text("以 \(login) 继续").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working)
                Text("使用这台 Mac 上 GitHub CLI（gh）的登录").font(.callout).foregroundStyle(.secondary)
            }
            orDivider
        case .expired:
            Label {
                Text("GitHub CLI 的登录已失效。在终端运行 ") + Text("gh auth login").font(.callout.monospaced())
                    + Text(" 后可一键连接，或者使用下面的令牌。")
            } icon: {
                Image(systemName: "terminal")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }

    private var orDivider: some View {
        HStack {
            VStack { Divider() }
            Text("或").font(.callout).foregroundStyle(.secondary)
            VStack { Divider() }
        }
    }

    private func checkCLI() async {
        guard let t = await GitHubCenter.cliToken() else {
            cli = .none
            tokenFocused = true
            return
        }
        if let login = await GitHubCenter.login(for: t) {
            cli = .ready(token: t, login: login)
        } else {
            cli = .expired
            tokenFocused = true
        }
    }

    private func connect(_ t: String) async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await github.connect(token: t)
            onDone()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Big rounded-square icon, title, one line of explanation; shared by the connection sheets.
struct ConnectHeader: View {
    let icon: Image
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            icon
                .resizable()
                .scaledToFit()
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .padding(13)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(tint.gradient))
                .padding(.bottom, 4)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
