import AistCore
import AppKit
import Foundation

/// One GitHub notification thread (GET /notifications).
struct GHNotification: Identifiable, Hashable, Codable {
    struct Subject: Hashable, Codable {
        var title: String
        var url: String?
        var type: String
    }
    struct Repo: Hashable, Codable {
        var full_name: String
        var html_url: String
    }

    var id: String
    var reason: String
    var unread: Bool
    var updated_at: Date
    var subject: Subject
    var repository: Repo

    var repo: String { repository.full_name }

    /// api.github.com/repos/o/r/pulls/12 → github.com/o/r/pull/12.
    var webURL: URL {
        if let api = subject.url, var path = URL(string: api)?.path, path.hasPrefix("/repos/") {
            path.removeFirst("/repos".count)
            path = path.replacingOccurrences(of: "/pulls/", with: "/pull/")
                .replacingOccurrences(of: "/commits/", with: "/commit/")
            if subject.type == "Release" { return URL(string: repository.html_url + "/releases")! }
            if let url = URL(string: "https://github.com" + path) { return url }
        }
        if subject.type == "Discussion" { return URL(string: repository.html_url + "/discussions")! }
        if subject.type == "CheckSuite" || reason == "ci_activity" { return URL(string: repository.html_url + "/actions")! }
        return URL(string: repository.html_url)!
    }

    /// "#123" for issues and pull requests.
    var number: String? {
        guard let last = subject.url?.split(separator: "/").last, Int(last) != nil,
              ["Issue", "PullRequest"].contains(subject.type) else { return nil }
        return "#\(last)"
    }

    var symbol: String {
        switch subject.type {
        case "PullRequest": "arrow.triangle.pull"
        case "Issue": "smallcircle.filled.circle"
        case "Release": "tag"
        case "Discussion": "bubble.left.and.bubble.right"
        case "Commit": "point.3.connected.trianglepath.dotted"
        case "CheckSuite", "WorkflowRun": "checkmark.seal"
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread": "exclamationmark.shield"
        default: "bell"
        }
    }

    var reasonLabel: String {
        switch reason {
        case "review_requested": "请你 Review"
        case "assign": "指派给你"
        case "mention": "提到了你"
        case "team_mention": "提到了你的团队"
        case "author": "你创建的"
        case "comment": "有新评论"
        case "state_change": "状态变化"
        case "subscribed", "manual": "关注中"
        case "ci_activity": "CI"
        case "security_alert": "安全提醒"
        case "invitation": "邀请"
        case "approval_requested": "等你批准"
        default: reason
        }
    }

    /// Notifications that are, in practice, a to-do for the user.
    /// GitHub only sends ci_activity for runs that failed (on workflows the user triggered), so those count too.
    var isActionable: Bool { ["review_requested", "assign", "approval_requested", "ci_activity"].contains(reason) }

    /// "Developer Runtime Packages workflow run failed for main branch" → ("Developer Runtime Packages", "main").
    var failedRun: (workflow: String, branch: String?)? {
        guard reason == "ci_activity" else { return nil }
        let t = subject.title
        guard let r = t.range(of: " workflow run", options: .caseInsensitive) else { return (t, nil) }
        let workflow = String(t[..<r.lowerBound])
        let branch = t.range(of: "for ").flatMap { f -> String? in
            let rest = t[f.upperBound...]
            return rest.hasSuffix(" branch") ? String(rest.dropLast(7)) : String(rest)
        }
        return (workflow, branch)
    }

    var isMainBranchFailure: Bool {
        guard let branch = failedRun?.branch?.lowercased() else { return false }
        return ["main", "master"].contains(branch) || branch.hasPrefix("release")
    }

    var todoTitle: String {
        switch reason {
        case "review_requested": "Review：\(subject.title)"
        case "approval_requested": "批准：\(subject.title)"
        case "assign": "处理：\(subject.title)"
        case "ci_activity":
            // Stable per workflow + branch, so repeated failures land on the same to-do.
            if let run = failedRun {
                "修复 CI：\(repository.full_name.split(separator: "/").last ?? "") · \(run.workflow)\(run.branch.map { "（\($0)）" } ?? "")"
            } else {
                "修复 CI：\(subject.title)"
            }
        default: subject.title
        }
    }
}

/// The issue / PR behind a notification, for the detail pane.
struct GHSubjectDetail: Hashable {
    var state: String?
    var merged: Bool
    var draft: Bool
    var author: String?
    var body: String?
}

enum GitHubError: LocalizedError {
    case badToken, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .badToken: "GitHub 令牌无效或已过期，请重新连接。"
        case let .http(code, message): "GitHub 返回 \(code)：\(message)"
        }
    }
}

/// GitHub as a connection: a token (classic PAT with `notifications`, or the GitHub CLI's login),
/// notifications polled the way the API asks (Last-Modified + X-Poll-Interval),
/// and review requests / assignments becoming to-dos.
@MainActor
final class GitHubCenter: ObservableObject {
    @Published private(set) var login: String?
    @Published private(set) var notifications: [GHNotification] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var connecting = false
    @Published private(set) var details: [String: GHSubjectDetail] = [:]

    private let store: TodoStore
    private var timer: Timer?
    private var lastModified: String?
    private var pollInterval: TimeInterval = 60

    private static let keychain = "com.aist.github"
    private static let loginKey = "github.login"
    private static let autoKey = "github.autoTodos"
    private static let seenKey = "github.convertedThreads"

    /// Turn review requests and assignments into to-dos by themselves.
    var autoTodos: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoKey)
            objectWillChange.send()
            if newValue { convertActionable() }
        }
    }

    /// Thread ids already turned into to-dos (with the update they were made from).
    private var converted: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.seenKey) }
    }

    var isConnected: Bool { login != nil }
    var unreadCount: Int { notifications.filter(\.unread).count }

    init(store: TodoStore) {
        self.store = store
        if token != nil { login = UserDefaults.standard.string(forKey: Self.loginKey) }
        if isConnected { start() }
    }

    private var token: String? { KeychainStore.read(service: Self.keychain, account: "token") }

    // MARK: Connecting

    /// The GitHub CLI's token, if `gh auth login` was done on this Mac.
    nonisolated static func cliToken() async -> String? {
        await Task.detached {
            for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = ["auth", "token"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { continue }
                p.waitUntilExit()
                let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus == 0, !token.isEmpty { return token }
            }
            return nil
        }.value
    }

    /// The account a token belongs to, or nil if GitHub rejects it.
    static func login(for token: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("aist", forHTTPHeaderField: "User-Agent")
        struct User: Decodable { var login: String }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(User.self, from: data))?.login
    }

    func connect(token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let (data, _) = try await request("/user", token: token)
        struct User: Decodable { var login: String }
        let user = try JSONDecoder().decode(User.self, from: data)
        // The notifications endpoint needs a classic token or OAuth; check now, not on the first poll.
        _ = try await request("/notifications?per_page=1", token: token)
        guard KeychainStore.write(token, service: Self.keychain, account: "token") else {
            throw GitHubError.http(0, "没能把令牌存进钥匙串")
        }
        UserDefaults.standard.set(user.login, forKey: Self.loginKey)
        login = user.login
        lastModified = nil
        start()
    }

    func disconnect() {
        timer?.invalidate()
        timer = nil
        _ = KeychainStore.delete(service: Self.keychain, account: "token")
        UserDefaults.standard.removeObject(forKey: Self.loginKey)
        login = nil
        notifications = []
        details = [:]
        error = nil
    }

    // MARK: Polling

    private func start() {
        Task { await refresh() }
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(pollInterval, 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refresh() } }
        }
    }

    /// `force` ignores Last-Modified (the toolbar button).
    private var lastRefresh: Date?

    func refreshIfStale() async {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 60 { return }
        await refresh()
    }

    func refresh(force: Bool = false) async {
        guard let token, !loading else { return }
        lastRefresh = .now
        loading = true
        defer {
            loading = false
            scheduleNext()
        }
        do {
            var headers: [String: String] = [:]
            if let lastModified, !force { headers["If-Modified-Since"] = lastModified }
            let (data, response) = try await request("/notifications?all=false&per_page=50", token: token, headers: headers)
            if let v = response.value(forHTTPHeaderField: "X-Poll-Interval"), let s = TimeInterval(v) { pollInterval = s }
            if response.statusCode == 304 { return }
            lastModified = response.value(forHTTPHeaderField: "Last-Modified")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let fresh = try decoder.decode([GHNotification].self, from: data).sorted { $0.updated_at > $1.updated_at }
            if fresh != notifications { notifications = fresh }
            error = nil
            convertActionable()
        } catch GitHubError.badToken {
            error = GitHubError.badToken.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Actions

    func markRead(_ n: GHNotification) async {
        guard let token, n.unread else { return }
        if let i = notifications.firstIndex(of: n) { notifications[i].unread = false }
        _ = try? await request("/notifications/threads/\(n.id)", method: "PATCH", token: token)
    }

    /// "Done" in GitHub's inbox: gone from the list.
    func markDone(_ n: GHNotification) async {
        guard let token else { return }
        notifications.removeAll { $0.id == n.id }
        _ = try? await request("/notifications/threads/\(n.id)", method: "DELETE", token: token)
    }

    func open(_ n: GHNotification) {
        NSWorkspace.shared.open(n.webURL)
        Task { await markRead(n) }
    }

    func todo(for n: GHNotification) -> TodoItem? {
        store.items.first { $0.link == n.webURL.absoluteString }
    }

    /// Makes (or returns) the to-do for a notification.
    @discardableResult
    func makeTodo(_ n: GHNotification) -> UUID {
        if let existing = todo(for: n) { return existing.id }
        // The same workflow failing again is the same job: refresh the open to-do instead of adding one.
        if let same = store.items.first(where: { $0.status == .open && $0.origin == .github && $0.title == n.todoTitle }) {
            store.update(same.id) {
                $0.link = n.webURL.absoluteString
                $0.evidence = "\(n.reasonLabel) · \(n.subject.title) · \(n.updated_at.formatted(date: .abbreviated, time: .shortened))"
                $0.updatedAt = .now
            }
            converted[n.id] = n.updated_at
            return same.id
        }
        let priority: TodoPriority = switch n.reason {
        case "review_requested": .high
        case "ci_activity": n.isMainBranchFailure ? .high : .medium
        default: .medium
        }
        var item = TodoItem(
            title: n.todoTitle,
            source: "GitHub · \(n.repo)\(n.number.map { " \($0)" } ?? "")",
            priority: priority,
            evidence: "\(n.reasonLabel) · \(n.subject.title)",
            origin: .github
        )
        item.link = n.webURL.absoluteString
        if n.reason == "ci_activity" {
            item.suggestion = n.isMainBranchFailure
                ? "\(n.failedRun?.branch ?? "main") 分支失败会阻塞发版。打开运行记录，先看失败 job 的 annotation 和日志。"
                : "打开运行记录，先看失败 job 的 annotation 和日志。"
        }
        store.insert(item)
        converted[n.id] = n.updated_at
        return item.id
    }

    private func convertActionable() {
        guard autoTodos else { return }
        let seen = converted
        for n in notifications where n.isActionable && n.unread && seen[n.id] == nil {
            // An old failure has likely been fixed or superseded since; only recent ones become to-dos.
            if n.reason == "ci_activity", n.updated_at < Date.now.addingTimeInterval(-48 * 3600) { continue }
            makeTodo(n)
        }
    }

    func loadDetail(_ n: GHNotification) async {
        guard let token, details[n.id] == nil, let api = n.subject.url,
              ["Issue", "PullRequest"].contains(n.subject.type),
              let path = URL(string: api)?.path else { return }
        struct Subject: Decodable {
            struct User: Decodable { var login: String }
            var state: String?
            var merged: Bool?
            var draft: Bool?
            var user: User?
            var body: String?
        }
        guard let (data, _) = try? await request(path, token: token),
              let s = try? JSONDecoder().decode(Subject.self, from: data) else { return }
        details[n.id] = GHSubjectDetail(state: s.state, merged: s.merged ?? false, draft: s.draft ?? false,
                                        author: s.user?.login, body: s.body?.nonEmpty)
    }

    // MARK: HTTP

    private func request(_ path: String, method: String = "GET", token: String,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("aist", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        switch http.statusCode {
        case 200..<300, 304: return (data, http)
        case 401: throw GitHubError.badToken
        default:
            struct Message: Decodable { var message: String }
            let message = (try? JSONDecoder().decode(Message.self, from: data))?.message ?? ""
            if http.statusCode == 403, message.localizedCaseInsensitiveContains("not accessible") {
                throw GitHubError.http(403, "这个令牌读不了通知。请用经典令牌（classic）并勾选 notifications。")
            }
            throw GitHubError.http(http.statusCode, message)
        }
    }
}
