import AistCore
import Combine
import Foundation
import SwiftMail

/// All mail state the UI shows: accounts, their folders, cached message lists, opened bodies.
/// Lists are cached on disk so the window shows mail instantly, then refreshes from the server.
@MainActor
final class MailCenter: ObservableObject {
    let accounts: MailAccountStore

    @Published private(set) var folders: [UUID: [MailFolder]] = [:]
    /// Message lists keyed by `key(account, folder)`, newest first.
    @Published private(set) var messages: [String: [MailHeader]] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var bodies: [String: MailBody] = [:]

    private var sessions: [UUID: MailSession] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?

    init(accounts: MailAccountStore) {
        self.accounts = accounts
        for account in accounts.accounts { loadCache(account.id) }
        accounts.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInboxes() }
        }
    }

    // MARK: Lookup

    func key(_ account: UUID, _ folder: String) -> String { "\(account.uuidString)/\(folder)" }

    func session(_ account: MailAccount) -> MailSession {
        if let s = sessions[account.id] { return s }
        let s = MailSession(account: account)
        sessions[account.id] = s
        return s
    }

    func folders(of account: UUID) -> [MailFolder] {
        folders[account] ?? [MailFolder(name: "INBOX", role: .inbox)]
    }

    func folder(_ account: UUID, role: MailFolder.Role) -> MailFolder? {
        folders(of: account).first { $0.role == role }
    }

    func inbox(of account: UUID) -> String { folder(account, role: .inbox)?.name ?? "INBOX" }

    func list(_ account: UUID, _ folder: String) -> [MailHeader] { messages[key(account, folder)] ?? [] }

    func unreadCount(_ account: UUID) -> Int { list(account, inbox(of: account)).filter { !$0.seen }.count }

    var totalUnread: Int { accounts.accounts.reduce(0) { $0 + unreadCount($1.id) } }

    func header(_ account: UUID, id: String) -> MailHeader? {
        for (k, list) in messages where k.hasPrefix(account.uuidString) {
            if let h = list.first(where: { $0.id == id }) { return h }
        }
        return nil
    }

    func body(_ account: UUID, _ header: MailHeader) -> MailBody? { bodies[account.uuidString + header.id] }

    // MARK: Accounts

    /// Saves the secret, checks the server accepts it, then keeps the account.
    func add(_ account: MailAccount, secret: String) async throws {
        account.storeSecret(secret)
        let session = MailSession(account: account)
        do {
            try await session.verify()
        } catch {
            account.deleteSecret()
            await session.close()
            throw error
        }
        sessions[account.id] = session
        accounts.add(account)
        await refresh(account.id, folder: nil)
    }

    func remove(_ id: UUID) {
        if let s = sessions.removeValue(forKey: id) { Task { await s.close() } }
        folders[id] = nil
        for k in messages.keys where k.hasPrefix(id.uuidString) { messages[k] = nil }
        try? FileManager.default.removeItem(at: cacheURL(id))
        accounts.remove(id)
    }

    // MARK: Sync

    func refreshInboxes() {
        for account in accounts.accounts {
            Task { await refresh(account.id, folder: nil) }
        }
    }

    /// Reload a folder (nil = inbox), and the folder list the first time.
    func refresh(_ id: UUID, folder: String?) async {
        guard let account = accounts.account(id) else { return }
        let session = session(account)
        if folders[id] == nil {
            do { folders[id] = try await session.folders() } catch { errors[id] = Self.describe(error) }
        }
        let name = folder ?? inbox(of: id)
        let k = key(id, name)
        guard !loading.contains(k) else { return }
        loading.insert(k)
        defer { loading.remove(k) }
        do {
            messages[k] = try await session.headers(in: name)
            errors[id] = nil
            saveCache(id)
        } catch {
            errors[id] = Self.describe(error)
        }
    }

    func loadBody(_ id: UUID, _ header: MailHeader) async throws -> MailBody {
        if let cached = body(id, header) { return cached }
        guard let account = accounts.account(id) else { throw MailError.noSecret }
        let body = try await session(account).body(uid: header.uid, in: header.mailbox)
        bodies[id.uuidString + header.id] = body
        if bodies.count > 60 { bodies.removeValue(forKey: bodies.keys.first!) }
        return body
    }

    // MARK: Actions (optimistic: the list changes at once, the server catches up)

    func setSeen(_ id: UUID, _ headers: [MailHeader], _ seen: Bool) {
        update(id, headers) { $0.seen = seen }
        perform(id) { try await $0.setFlag(.seen, seen, uids: headers.map(\.uid), in: headers[0].mailbox) }
    }

    func setFlagged(_ id: UUID, _ headers: [MailHeader], _ flagged: Bool) {
        update(id, headers) { $0.flagged = flagged }
        perform(id) { try await $0.setFlag(.flagged, flagged, uids: headers.map(\.uid), in: headers[0].mailbox) }
    }

    func archive(_ id: UUID, _ headers: [MailHeader]) {
        guard let target = folder(id, role: .archive) ?? folder(id, role: .all) else { return }
        moveOut(id, headers, to: target.name)
    }

    func canArchive(_ id: UUID) -> Bool {
        folder(id, role: .archive) != nil || folder(id, role: .all) != nil
    }

    func delete(_ id: UUID, _ headers: [MailHeader]) {
        guard let first = headers.first else { return }
        if let trash = folder(id, role: .trash), trash.name != first.mailbox {
            moveOut(id, headers, to: trash.name)
        } else {
            removeLocally(id, headers)
            perform(id) { try await $0.expunge(uids: headers.map(\.uid), in: first.mailbox) }
        }
    }

    func moveOut(_ id: UUID, _ headers: [MailHeader], to destination: String) {
        guard let first = headers.first else { return }
        removeLocally(id, headers)
        perform(id) { try await $0.move(uids: headers.map(\.uid), from: first.mailbox, to: destination) }
    }

    func send(from id: UUID, _ mail: OutgoingMail) async throws {
        guard let account = accounts.account(id) else { throw MailError.noSecret }
        let session = session(account)
        let email = try await session.send(mail)
        if !account.provider.savesSentCopy, let sent = folder(id, role: .sent) {
            try? await session.appendSent(email, to: sent.name)
        }
        if let sent = folder(id, role: .sent) { Task { await refresh(id, folder: sent.name) } }
    }

    private func update(_ id: UUID, _ headers: [MailHeader], _ change: (inout MailHeader) -> Void) {
        let ids = Set(headers.map(\.id))
        for k in messages.keys where k.hasPrefix(id.uuidString) {
            guard var list = messages[k] else { continue }
            for i in list.indices where ids.contains(list[i].id) { change(&list[i]) }
            messages[k] = list
        }
        saveCache(id)
    }

    private func removeLocally(_ id: UUID, _ headers: [MailHeader]) {
        let ids = Set(headers.map(\.id))
        for k in messages.keys where k.hasPrefix(id.uuidString) {
            messages[k]?.removeAll { ids.contains($0.id) }
        }
        saveCache(id)
    }

    /// Runs a server change; on failure shows the error and reloads the truth.
    private func perform(_ id: UUID, _ work: @escaping @Sendable (MailSession) async throws -> Void) {
        guard let account = accounts.account(id) else { return }
        let session = session(account)
        Task {
            do {
                try await work(session)
            } catch {
                errors[id] = Self.describe(error)
                await refresh(id, folder: nil)
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("unsafe login") {
            return "服务器拒绝登录（Unsafe Login）：请确认已在网页版开启 IMAP 并使用授权码"
        }
        if text.localizedCaseInsensitiveContains("auth") || text.localizedCaseInsensitiveContains("login") {
            return "登录失败：请检查邮箱地址和授权码 / 密码"
        }
        return text
    }

    // MARK: Cache

    private func cacheURL(_ id: UUID) -> URL {
        MailAccountStore.directory.appendingPathComponent("\(id.uuidString).json")
    }

    private struct Cache: Codable {
        var folders: [MailFolder]?
        var messages: [String: [MailHeader]]
    }

    private func saveCache(_ id: UUID) {
        var lists: [String: [MailHeader]] = [:]
        for (k, list) in messages where k.hasPrefix(id.uuidString) {
            lists[String(k.dropFirst(id.uuidString.count + 1))] = Array(list.prefix(200))
        }
        let cache = Cache(folders: folders[id], messages: lists)
        let url = cacheURL(id)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func loadCache(_ id: UUID) {
        guard let data = try? Data(contentsOf: cacheURL(id)),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        if let f = cache.folders { folders[id] = f }
        for (folder, list) in cache.messages { messages[key(id, folder)] = list }
    }
}
