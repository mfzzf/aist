import AistCore
import AppKit
import SwiftUI
import WebKit

struct MailActions {
    var compose: (ComposeDraft) -> Void
}

enum MailFormat {
    /// List column: "14:02" today, "昨天", weekday this week, else "2026/10/28".
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return DueFormatter.time(date) }
        if cal.isDateInYesterday(date) { return "昨天" }
        let zh = Locale(identifier: "zh_CN")
        if Date.now.timeIntervalSince(date) < 6 * 86400 { return date.formatted(.dateTime.weekday(.wide).locale(zh)) }
        return date.formatted(.dateTime.year().month(.defaultDigits).day().locale(zh))
    }

    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN")))
            + " " + DueFormatter.time(date)
    }

    /// "a@x.com, Name <b@y.com>; c@z.com" → bare addresses.
    static func addresses(_ text: String) -> [String] {
        text.split(whereSeparator: { ",;，；\n".contains($0) }).compactMap { part in
            let s = part.trimmingCharacters(in: .whitespaces)
            if let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close {
                return String(s[s.index(after: open)..<close])
            }
            return s.contains("@") ? s : nil
        }
    }
}

// MARK: - Sidebar

struct MailSidebarSection: View {
    @ObservedObject var model: MainModel
    @ObservedObject var mail: MailCenter
    @State private var removing: MailAccount?

    var body: some View {
        Section("邮件") {
            ForEach(mail.accounts.accounts) { account in
                DisclosureGroup {
                    ForEach(mail.folders(of: account.id).filter { $0.role != .inbox }) { folder in
                        Label(folder.title, systemImage: folder.symbol)
                            .tag(MainModel.Pane.mail(account.id, folder.name))
                    }
                } label: {
                    Label {
                        Text(account.email).lineLimit(1)
                    } icon: {
                        if mail.errors[account.id] != nil {
                            Image(systemName: "exclamationmark.triangle")
                        } else {
                            AccountIcon(provider: account.provider)
                        }
                    }
                    .badge(mail.unreadCount(account.id))
                    .tag(MainModel.Pane.mail(account.id, mail.inbox(of: account.id)))
                    .help(mail.errors[account.id] ?? account.provider.name)
                    .contextMenu {
                        Button("收取邮件") { Task { await mail.refresh(account.id, folder: nil) } }
                        Divider()
                        Button("移除账户…", role: .destructive) { removing = account }
                    }
                }
            }
            Button { model.addingAccount = true } label: {
                Label("添加邮箱…", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .confirmationDialog("移除「\(removing?.email ?? "")」？", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("移除账户", role: .destructive) {
                guard let account = removing else { return }
                if model.pane.mailAccount == account.id { model.pane = .todos }
                mail.remove(account.id)
                removing = nil
            }
        } message: {
            Text("只从 Aist 里移除，服务器上的邮件不受影响。")
        }
    }
}

// MARK: - List

struct MailListColumn: View {
    @ObservedObject var model: MainModel
    @ObservedObject private var log = MailAnalysisLog.shared
    @ObservedObject var mail: MailCenter
    let account: UUID
    let folder: String
    let actions: MailActions

    private var role: MailFolder.Role { mail.folders(of: account).first { $0.name == folder }?.role ?? .other }
    private var showsRecipient: Bool { role == .sent || role == .drafts }

    private var headers: [MailHeader] {
        let all = mail.list(account, folder)
        let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { h in
            [h.subject, h.fromName, h.fromAddress, h.to.joined(separator: " ")].contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        List(selection: $model.mailSelection) {
            if let error = mail.errors[account] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.subheadline)
                    .selectionDisabled()
            }
            ForEach(headers) { header in
                MailRow(header: header, showsRecipient: showsRecipient, analysis: log.status(account, header))
                    .tag(header.id)
                    .contextMenu { menu(header) }
                    .swipeActions(edge: .leading) {
                        Button { mail.setSeen(account, [header], !header.seen) } label: {
                            Label(header.seen ? "标为未读" : "标为已读",
                                  systemImage: header.seen ? "envelope.badge" : "envelope.open")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { remove(header) } label: { Label("删除", systemImage: "trash") }
                        if mail.canArchive(account), role != .archive {
                            Button { archive(header) } label: { Label("归档", systemImage: "archivebox") }
                                .tint(.purple)
                        }
                    }
            }
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty, mail.hasMore(account, folder) {
                // Older mail loads as the end of the list scrolls into view, like Mail.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .selectionDisabled()
                    // Re-armed when a refresh that blocked it finishes, not only when rows arrive.
                    .task(id: [headers.count, mail.loading.contains(mail.key(account, folder)) ? 1 : 0]) {
                        await mail.loadMore(account, folder: folder)
                    }
            }
        }
        .listStyle(.inset)
        .animation(.default, value: headers.map(\.id))
        .overlay {
            if headers.isEmpty {
                if mail.loading.contains(mail.key(account, folder)) {
                    ProgressView()
                } else if !model.query.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else if mail.errors[account] == nil {
                    ContentUnavailableView("没有邮件", systemImage: "tray")
                }
            }
        }
        .task(id: folder) { await mail.refresh(account, folder: folder) }
    }

    @ViewBuilder private func menu(_ header: MailHeader) -> some View {
        Button(header.seen ? "标为未读" : "标为已读") { mail.setSeen(account, [header], !header.seen) }
        Button(header.flagged ? "取消旗标" : "加旗标") { mail.setFlagged(account, [header], !header.flagged) }
        Divider()
        if mail.canArchive(account), role != .archive {
            Button("归档") { archive(header) }
        }
        Button("删除", role: .destructive) { remove(header) }
    }

    private func archive(_ header: MailHeader) {
        if model.mailSelection == header.id { model.mailSelection = nil }
        mail.archive(account, [header])
    }

    private func remove(_ header: MailHeader) {
        if model.mailSelection == header.id { model.mailSelection = nil }
        mail.delete(account, [header])
    }
}

private struct MailRow: View {
    let header: MailHeader
    let showsRecipient: Bool
    let analysis: MailAnalysisLog.Status?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(header.seen ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(showsRecipient ? (header.to.first ?? "（无收件人）") : header.sender)
                        .fontWeight(header.seen ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let analysis { AnalysisMark(status: analysis) }
                    if header.flagged {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange)
                    }
                    Text(MailFormat.short(header.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if header.answered {
                        Image(systemName: "arrowshape.turn.up.left.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(header.subject)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Small mark in a mail row: what the AI made of the message.
private struct AnalysisMark: View {
    let status: MailAnalysisLog.Status

    var body: some View {
        switch status {
        case .analyzing:
            ProgressView().controlSize(.mini).help("AI 正在分析")
        case let .todos(ids, _):
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(AistBrand.gradient)
                .help("AI 已分析：\(ids.count) 项待办")
        case .nothing:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("AI 已分析：没有待办")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("AI 分析失败")
        }
    }
}

// MARK: - Reading

struct MailDetail: View {
    let header: MailHeader
    let account: UUID
    @ObservedObject var model: MainModel
    @ObservedObject var mail: MailCenter
    @ObservedObject var store: TodoStore
    let actions: MailActions

    @State private var body_: MailBody?
    @State private var error: String?
    @ObservedObject private var log = MailAnalysisLog.shared

    private var analysis: MailAnalysisLog.Status? { log.status(account, header) }
    private var analyzing: Bool { analysis == .analyzing }

    private var myAddress: String { mail.accounts.account(account)?.email ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
            analysisBar
            Divider()
            if let body_ {
                MailWebView(html: Self.page(for: body_), plain: body_.html == nil)
                if !body_.attachments.isEmpty { attachmentsBar(body_.attachments) }
            } else if let error {
                ContentUnavailableView("无法载入邮件", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar { toolbar }
        .task {
            do {
                body_ = try await mail.loadBody(account, header)
                if !header.seen { mail.setSeen(account, [header], true) }
            } catch {
                self.error = MailCenter.describe(error)
            }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(header.subject)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 10) {
                Text(String(header.sender.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.gray.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(header.sender).font(.headline)
                        if !header.fromName.isEmpty {
                            Text(header.fromAddress).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(MailFormat.long(header.date)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !header.to.isEmpty {
                        Text("收件人：" + header.to.joined(separator: "，"))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !header.cc.isEmpty {
                        Text("抄送：" + header.cc.joined(separator: "，"))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    /// Always shown, so it's clear at a glance whether the AI has read this email and what it found.
    private var analysisBar: some View {
        HStack(spacing: 8) {
            switch analysis {
            case nil:
                Label("AI 尚未分析这封邮件", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("分析待办") { Task { await analyze() } }
                    .controlSize(.small)
                    .disabled(body_ == nil)
            case .analyzing:
                ProgressView().controlSize(.small)
                Text("AI 正在分析…").foregroundStyle(.secondary)
                Spacer()
            case let .todos(ids, at):
                let live = ids.filter { id in store.items.contains { $0.id == id } }
                Label {
                    Text(live.isEmpty ? "AI 已分析 · 提取的待办已删除" : "AI 已分析 · \(live.count) 项待办")
                        + Text(" · \(Self.relative(at))").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(AistBrand.gradient)
                }
                Spacer()
                if let first = live.first {
                    Button("查看") {
                        model.pane = .todos
                        model.selection = first
                    }
                    .controlSize(.small)
                }
                reanalyze
            case let .nothing(at):
                Label {
                    Text("AI 已分析 · 没有需要你做的事")
                        + Text(" · \(Self.relative(at))").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                }
                Spacer()
                reanalyze
            case let .failed(text, _):
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(2)
                Spacer()
                Button("重试") { Task { await analyze() } }
                    .controlSize(.small)
                    .disabled(body_ == nil)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.4))
        .animation(.default, value: analysis)
    }

    private var reanalyze: some View {
        Button { Task { await analyze() } } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless)
            .help("重新分析")
            .disabled(body_ == nil)
    }

    private static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func attachmentsBar(_ attachments: [MailAttachment]) -> some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { a in
                        Button { open(a) } label: {
                            Label("\(a.filename)（\(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))）",
                                  systemImage: "paperclip")
                        }
                        .contextMenu {
                            Button("打开") { open(a) }
                            Button("存储…") { save(a) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { reply(all: false) } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
                .help("回复")
                .disabled(body_ == nil)
            Button { reply(all: true) } label: { Label("全部回复", systemImage: "arrowshape.turn.up.left.2") }
                .help("全部回复")
                .disabled(body_ == nil)
            Button { forward() } label: { Label("转发", systemImage: "arrowshape.turn.up.right") }
                .help("转发")
                .disabled(body_ == nil)
        }
        ToolbarItemGroup {
            Button { Task { await analyze() } } label: {
                Label("分析待办", systemImage: analyzing ? "hourglass" : "sparkles")
            }
            .help("让 AI 从这封邮件里找出你的待办")
            .disabled(body_ == nil || analyzing)
            Button { mail.setFlagged(account, [header], !header.flagged) } label: {
                Label(header.flagged ? "取消旗标" : "旗标", systemImage: header.flagged ? "flag.slash" : "flag")
            }
            .help(header.flagged ? "取消旗标" : "加旗标")
            if mail.canArchive(account) {
                Button {
                    model.mailSelection = nil
                    mail.archive(account, [header])
                } label: { Label("归档", systemImage: "archivebox") }
                .help("归档")
            }
            Button {
                model.mailSelection = nil
                mail.delete(account, [header])
            } label: { Label("删除", systemImage: "trash") }
            .help("删除")
        }
    }

    // MARK: Actions

    private func reply(all: Bool) {
        guard let body_ else { return }
        actions.compose(.reply(to: header, body: body_, account: account, myAddress: myAddress, all: all))
    }

    private func forward() {
        guard let body_ else { return }
        actions.compose(.forward(header, body: body_, account: account))
    }

    private func analyze() async {
        guard let body_, !analyzing else { return }
        // The log records the outcome (and any error) for the status bar.
        _ = try? await MailAutoTodo.analyze(header: header, body: body_, account: account,
                                            myAddress: myAddress, store: store)
    }

    private func open(_ a: MailAttachment) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aist-attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(a.filename)
        if (try? a.data.write(to: file)) != nil { NSWorkspace.shared.open(file) }
    }

    private func save(_ a: MailAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? a.data.write(to: url)
    }

    // MARK: Page

    static func page(for body: MailBody) -> String {
        if let html = body.html {
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="color-scheme" content="light">
            <style>body{margin:16px 20px;font:-apple-system-body;word-wrap:break-word}img{max-width:100%;height:auto}</style>
            </head><body>\(html)</body></html>
            """
        }
        let escaped = (body.text ?? "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>:root{color-scheme:light dark}body{margin:16px 20px;font:-apple-system-body;white-space:pre-wrap;word-wrap:break-word}</style>
        </head><body>\(escaped)</body></html>
        """
    }
}

/// Mail body in WebKit: no JavaScript, links open in the default browser.
struct MailWebView: NSViewRepresentable {
    let html: String
    /// Plain-text mail follows the window's appearance; HTML mail keeps its own (light) design.
    let plain: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.setValue(!plain, forKey: "drawsBackground")
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// The service's logo where there is one (QQ, Gmail, iCloud, Tencent Exmail), else an envelope.
struct AccountIcon: View {
    let provider: MailProvider

    var body: some View {
        switch provider {
        case .qq, .exmail: BrandIcon(image: BrandMark.qq).foregroundStyle(BrandColor.qq)
        case .gmail: BrandIcon(image: BrandMark.gmail).foregroundStyle(BrandColor.gmail)
        case .icloud: BrandIcon(image: BrandMark.icloud, size: 17).foregroundStyle(BrandColor.icloud)
        default: Image(systemName: "envelope")
        }
    }
}
