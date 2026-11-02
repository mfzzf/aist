import AistCore
import Combine
import Foundation
import UserNotifications

/// Reads new inbox mail and files any to-dos it finds — the automatic version of 「分析待办」.
/// Only mail that arrives after it's switched on is read; each message once.
@MainActor
final class MailAutoTodo: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled, !oldValue { markAllSeen() }
        }
    }
    @Published private(set) var working = false

    private let mail: MailCenter
    private let store: TodoStore
    private var subscription: AnyCancellable?
    private var processed: Set<String>
    private var queue: [(UUID, MailHeader)] = []

    private static let enabledKey = "mail.autoTodos"
    private static let processedKey = "mail.autoTodos.processed"

    init(mail: MailCenter, store: TodoStore) {
        self.mail = mail
        self.store = store
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        processed = Set(UserDefaults.standard.stringArray(forKey: Self.processedKey) ?? [])
        subscription = mail.$messages
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scan() }
    }

    private func key(_ account: UUID, _ h: MailHeader) -> String { "\(account.uuidString)/\(h.mailbox)/\(h.uid)" }

    private var inboxes: [(UUID, [MailHeader])] {
        mail.accounts.accounts.map { ($0.id, mail.list($0.id, mail.inbox(of: $0.id))) }
    }

    /// Switching on: what's already in the inbox counts as read, so it doesn't analyse a backlog of hundreds.
    private func markAllSeen() {
        for (account, headers) in inboxes { for h in headers { processed.insert(key(account, h)) } }
        save()
    }

    private func save() {
        // Keep the newest few thousand; old UIDs never come back.
        if processed.count > 5000 { processed = Set(processed.shuffled().prefix(4000)) }
        UserDefaults.standard.set(Array(processed), forKey: Self.processedKey)
    }

    private func scan() {
        guard enabled else { return }
        let cutoff = Date.now.addingTimeInterval(-3 * 86400)
        for (account, headers) in inboxes {
            for h in headers where !processed.contains(key(account, h)) {
                processed.insert(key(account, h))
                // A new account's first load brings old mail too; only recent mail is worth reading.
                if h.date > cutoff { queue.append((account, h)) }
            }
        }
        save()
        drain()
    }

    private func drain() {
        guard !working, !queue.isEmpty else { return }
        let (account, header) = queue.removeFirst()
        working = true
        Task {
            defer { working = false; drain() }
            guard let body = try? await mail.loadBody(account, header) else { return }
            let address = mail.accounts.account(account)?.email ?? ""
            guard let result = try? await Self.analyze(header: header, body: body, account: account,
                                                       myAddress: address, store: store),
                  !result.added.isEmpty
            else { return }
            notify(added: result.added.count, subject: header.subject)
        }
    }

    private func notify(added: Int, subject: String) {
        let content = UNMutableNotificationContent()
        content.title = "从邮件里发现 \(added) 条待办"
        content.body = subject
        content.threadIdentifier = "mail-todos"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Shared with the 「分析待办」 button: one message → to-dos in the store.
    static func analyze(header: MailHeader, body: MailBody, account: UUID, myAddress: String,
                        store: TodoStore) async throws -> TodoStore.ApplyResult {
        let log = MailAnalysisLog.shared
        log.set(.analyzing, account, header)
        do {
            let result = try await run(header: header, body: body, account: account, myAddress: myAddress, store: store)
            let ids = result.added + result.updated
            log.set(ids.isEmpty ? .nothing(at: .now) : .todos(ids, at: .now), account, header)
            return result
        } catch {
            log.set(.failed(error.localizedDescription, at: .now), account, header)
            throw error
        }
    }

    private static func run(header: MailHeader, body: MailBody, account: UUID, myAddress: String,
                            store: TodoStore) async throws -> TodoStore.ApplyResult {
        let config = try LLMConfig.load()
        var text = "发件人：\(header.sender) <\(header.fromAddress)>\n"
        text += "收件人：\(header.to.joined(separator: ", "))\n"
        if !header.cc.isEmpty { text += "抄送：\(header.cc.joined(separator: ", "))\n" }
        text += "用户本人的地址：\(myAddress)\n"
        text += "时间：\(header.date.formatted(.iso8601))\n主题：\(header.subject)\n\n\(body.plainText)"
        var identity = UserIdentity.names
        if !myAddress.isEmpty, !identity.contains(myAddress) { identity.append(myAddress) }
        let extracted = try await TodoExtractor(client: LLMClient(config: config), identity: identity)
            .extract(email: text, existing: store.openItems)
        let ref = EmailRef(accountID: account, mailbox: header.mailbox, uid: header.uid, subject: header.subject)
        return store.apply(extracted.map { e in
            var e = e
            if e.source == nil || e.source == "邮件" { e.source = "邮件：\(header.subject)" }
            return e
        }, origin: .email, emailRef: ref)
    }
}
