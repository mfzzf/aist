import AistCore
import Foundation
import SwiftMail

// MARK: - Models the UI works with (plain values, cached on disk)

struct MailFolder: Codable, Hashable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case inbox, flagged, drafts, sent, archive, junk, trash, all, other }

    var name: String
    var role: Role
    var id: String { name }

    var title: String {
        switch role {
        case .inbox: "收件箱"
        case .flagged: "旗标"
        case .drafts: "草稿"
        case .sent: "已发送"
        case .archive: "归档"
        case .junk: "垃圾邮件"
        case .trash: "废纸篓"
        case .all: "所有邮件"
        case .other: Self.decodeIMAPUTF7(name).split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? name
        }
    }

    /// IMAP folder names are "modified UTF-7" (RFC 3501 §5.1.3): `&V4NXPpCuTvY-` is 垃圾邮件.
    /// Non-ASCII runs sit between & and -, as base64 of UTF-16BE with "," for "/"; "&-" is a literal &.
    static func decodeIMAPUTF7(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let dash = after.firstIndex(of: "-") else { out += rest[amp...]; return out }
            let chunk = after[..<dash]
            if chunk.isEmpty {
                out += "&"
            } else {
                var b64 = chunk.replacingOccurrences(of: ",", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                if let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf16BigEndian) {
                    out += text
                } else {
                    out += "&" + chunk + "-"
                }
            }
            rest = after[after.index(after: dash)...]
        }
        return out + rest
    }

    var symbol: String {
        switch role {
        case .inbox: "tray"
        case .flagged: "flag"
        case .drafts: "doc"
        case .sent: "paperplane"
        case .archive: "archivebox"
        case .junk: "xmark.bin"
        case .trash: "trash"
        case .all: "tray.full"
        case .other: "folder"
        }
    }

    var order: Int {
        [.inbox, .flagged, .drafts, .sent, .archive, .all, .junk, .trash, .other].firstIndex(of: role) ?? 99
    }
}

struct MailHeader: Codable, Hashable, Identifiable, Sendable {
    var uid: UInt32
    var mailbox: String
    var subject: String
    var fromName: String
    var fromAddress: String
    var replyTo: String?
    var to: [String]
    var cc: [String]
    var date: Date
    var seen: Bool
    var flagged: Bool
    var answered: Bool
    var messageID: String?
    var references: [String]

    var id: String { "\(mailbox)\u{1}\(uid)" }
    var sender: String { fromName.isEmpty ? fromAddress : fromName }
}

struct MailAttachment: Identifiable, Sendable {
    let id = UUID()
    var filename: String
    var contentType: String
    var data: Data
}

struct MailBody: Sendable {
    var text: String?
    var html: String?
    var attachments: [MailAttachment]

    /// Readable plain text for replies, quoting and AI analysis.
    /// The readable text. Many mails carry a stub plain part ("请使用支持 HTML 的客户端查看") next to the
    /// real HTML, so the longer of the two wins.
    var plainText: String {
        let plain = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var fromHTML = ""
        if let html, let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil) {
            fromHTML = attributed.string
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\n\\s*\n+", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fromHTML.count > plain.count ? fromHTML : plain
    }
}

/// A message to send.
struct OutgoingMail: Sendable {
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
    var inReplyTo: String?
    var references: [String]
    var attachments: [MailAttachment] = []
}

enum MailError: LocalizedError {
    case noSecret
    case send(String)

    var errorDescription: String? {
        switch self {
        case .noSecret: "钥匙串里找不到这个账户的密码，请删除后重新添加"
        case let .send(text): "发送失败：\(text)"
        }
    }
}

// MARK: - Session

/// One account's IMAP connection (SwiftMail), reused across calls and re-opened once on failure.
struct MailPage: Sendable {
    var headers: [MailHeader]
    /// Messages in the whole folder.
    var total: Int
}

actor MailSession {
    let account: MailAccount
    private var imap: IMAPServer?
    private var selected: String?
    /// Folders whose ENVELOPE replies the IMAP parser rejects (QQ Mail sends some it can't read).
    private var envelopeless: Set<String> = []
    /// Every message's UID and arrival time, per folder, so "newest" means newest by date.
    /// Kept on disk: building it reads every message's date, about a second per thousand on QQ.
    private lazy var indexes: [String: FolderIndex] = {
        guard let data = try? Data(contentsOf: Self.indexURL(account.id)) else { return [:] }
        return (try? JSONDecoder().decode([String: FolderIndex].self, from: data)) ?? [:]
    }()

    static func indexURL(_ id: UUID) -> URL {
        MailAccountStore.directory.appendingPathComponent("\(id.uuidString)-index.json")
    }

    private struct FolderIndex: Codable {
        var validity: UIDValidity?
        var uidNext: SwiftMail.UID?
        var dates: [UInt32: Date] = [:]
    }

    init(account: MailAccount) { self.account = account }

    /// NetEase (163/126) refuse SELECT until the client sends RFC 2971 ID; harmless elsewhere.
    private static let identification = Identification(
        name: "aist", version: "1.0", os: "macOS", vendor: "aist", supportURL: "https://github.com/"
    )

    private func connected() async throws -> IMAPServer {
        if let imap { return imap }
        let server = IMAPServer(host: account.imapHost, port: account.imapPort)
        try await server.connect()
        await server.setClientIdentification(Self.identification)
        switch account.auth {
        case .password:
            guard let secret = account.secret else { throw MailError.noSecret }
            try await server.login(username: account.email, password: secret)
        case .oauth:
            let account = self.account
            let token = try await OAuthClient.accessToken(for: account)
            try await server.authenticateXOAUTH2(email: account.email, accessToken: token)
            await server.setXOAUTH2AccessTokenProvider(email: account.email) {
                try await OAuthClient.accessToken(for: account)
            }
        }
        imap = server
        selected = nil
        return server
    }

    func close() async {
        if let imap { try? await imap.logout() }
        imap = nil
        selected = nil
    }

    /// Run against the live connection; if it has gone stale, reconnect once and retry.
    private func withServer<T: Sendable>(_ body: (IMAPServer) async throws -> T) async throws -> T {
        do {
            return try await body(connected())
        } catch {
            if let imap { try? await imap.disconnect() }
            imap = nil
            selected = nil
            return try await body(connected())
        }
    }

    private func select(_ mailbox: String, on server: IMAPServer, force: Bool = false) async throws -> Mailbox.Selection? {
        guard force || selected != mailbox else { return nil }
        let selection = try await server.selectMailbox(mailbox)
        selected = mailbox
        return selection
    }

    /// Checks the credentials work (used when adding an account).
    func verify() async throws {
        _ = try await withServer { server in try await server.listMailboxes() }
    }

    func folders() async throws -> [MailFolder] {
        let infos = try await withServer { server in try await server.listMailboxes() }
        return infos.filter(\.isSelectable).map { info in
            MailFolder(name: info.name, role: Self.role(of: info))
        }
        .sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    private static func role(of info: Mailbox.Info) -> MailFolder.Role {
        let a = info.attributes
        if info.name.uppercased() == "INBOX" || a.contains(.inbox) { return .inbox }
        if a.contains(.sent) { return .sent }
        if a.contains(.drafts) { return .drafts }
        if a.contains(.trash) { return .trash }
        if a.contains(.junk) { return .junk }
        if a.contains(.archive) { return .archive }
        if a.contains(.all) { return .all }
        if a.contains(.flagged) { return .flagged }
        // Servers without SPECIAL-USE (QQ, NetEase) name them instead.
        let n = MailFolder.decodeIMAPUTF7(info.name).lowercased()
        if ["sent messages", "sent", "sent items", "已发送", "已发送邮件"].contains(n) { return .sent }
        if ["drafts", "draft", "草稿箱", "草稿"].contains(n) { return .drafts }
        if ["deleted messages", "trash", "deleted items", "已删除", "已删除邮件", "废纸篓"].contains(n) { return .trash }
        if ["junk", "spam", "junk e-mail", "垃圾邮件", "垃圾箱", "垃圾"].contains(n) { return .junk }
        if ["archive", "归档"].contains(n) { return .archive }
        return .other
    }

    /// One page of a folder, newest first by arrival time, and how many messages the folder has.
    func headers(in mailbox: String, offset: Int = 0, limit: Int = 100) async throws -> MailPage {
        if !envelopeless.contains(mailbox) {
            do {
                return try await page(in: mailbox, offset: offset, limit: limit, envelope: true)
            } catch where Self.isParseFailure(error) {
                // One malformed ENVELOPE fails the whole FETCH. Read the header lines instead,
                // which SwiftMail decodes itself, and remember to skip ENVELOPE for this folder.
                envelopeless.insert(mailbox)
            }
        }
        return try await page(in: mailbox, offset: offset, limit: limit, envelope: false)
    }

    private static let headerFields = ["Date", "Subject", "From", "Reply-To", "To", "Cc", "Message-ID", "References"]

    private func page(in mailbox: String, offset: Int, limit: Int, envelope: Bool) async throws -> MailPage {
        try await withServer { server in
            guard let selection = try await select(mailbox, on: server, force: true) else {
                return MailPage(headers: [], total: 0)
            }
            let order = try await newestFirst(mailbox, selection, on: server)
            let uids = order.dropFirst(offset).prefix(limit).map { SwiftMail.UID($0) }
            guard !uids.isEmpty else { return MailPage(headers: [], total: order.count) }
            let infos = try await server.fetchMessageInfosBulk(
                using: UIDSet(Array(uids)),
                options: envelope ? [.envelope, .flags, .internalDate] : [.flags, .internalDate],
                headerFields: envelope ? ["References"] : Self.headerFields
            )
            let headers = infos.compactMap { Self.header($0, mailbox: mailbox) }.sorted { $0.date > $1.date }
            return MailPage(headers: headers, total: order.count)
        }
    }

    /// The folder's UIDs, newest arrival first. Sequence numbers can't stand in for this: QQ Mail
    /// numbers messages out of date order, so the highest numbers can be a batch of years-old mail.
    private func newestFirst(_ mailbox: String, _ selection: Mailbox.Selection, on server: IMAPServer) async throws -> [UInt32] {
        let count = selection.messageCount
        var index = indexes[mailbox] ?? FolderIndex()
        let known = index.validity == selection.uidValidity && !index.dates.isEmpty
        if count == 0 {
            index.dates = [:]
        } else if known, index.uidNext != nil, index.uidNext == selection.uidNext, index.dates.count == count {
            // Nothing arrived or left since last time.
        } else if known {
            // Drop what left, then read dates only for UIDs not seen before.
            let live: UIDSet = try await server.search(criteria: [.all])
            let uids = Set(live.toArray().map(\.value))
            index.dates = index.dates.filter { uids.contains($0.key) }
            let fresh = uids.subtracting(index.dates.keys).sorted().map { SwiftMail.UID($0) }
            for start in stride(from: 0, to: fresh.count, by: 2000) {
                let chunk = Array(fresh[start..<min(fresh.count, start + 2000)])
                index.dates.merge(try await arrivals(UIDSet(chunk), on: server)) { _, new in new }
            }
            if index.dates.count != count { index.dates = try await allArrivals(count, on: server) }
        } else {
            index.dates = try await allArrivals(count, on: server)
        }
        let changed = index.validity != selection.uidValidity || index.uidNext != selection.uidNext
            || index.dates.keys != indexes[mailbox]?.dates.keys
        index.validity = selection.uidValidity
        index.uidNext = selection.uidNext
        indexes[mailbox] = index
        if changed { saveIndexes() }
        return index.dates.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.map(\.key)
    }

    private func saveIndexes() {
        guard let data = try? JSONEncoder().encode(indexes) else { return }
        let url = Self.indexURL(account.id)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Arrival times of every message, a few thousand per FETCH so each answers within SwiftMail's timeout.
    private func allArrivals(_ count: Int, on server: IMAPServer) async throws -> [UInt32: Date] {
        var dates: [UInt32: Date] = [:]
        for start in stride(from: 1, through: count, by: 2000) {
            let end = min(count, start + 1999)
            dates.merge(try await arrivals(SequenceNumberSet(start...end), on: server)) { _, new in new }
        }
        return dates
    }

    private func arrivals<T: MessageIdentifier>(_ set: MessageIdentifierSet<T>, on server: IMAPServer) async throws -> [UInt32: Date] {
        let infos = try await server.fetchMessageInfosBulk(using: set, options: [.internalDate])
        var dates: [UInt32: Date] = [:]
        for info in infos {
            guard let uid = info.uid else { continue }
            dates[uid.value] = info.internalDate ?? info.date ?? .distantPast
        }
        return dates
    }

    /// swift-nio-imap reports unparseable server replies as IMAPDecoderError wrapping a ParserError.
    private static func isParseFailure(_ error: Error) -> Bool {
        let text = String(reflecting: error)
        return text.contains("IMAPDecoderError") || text.contains("ParserError")
    }

    private static func header(_ info: MessageInfo, mailbox: String) -> MailHeader? {
        guard let uid = info.uid else { return nil }
        let from = info.fromAddresses.mailboxes.first
        // SwiftMail moves References out of the extra header fields into its own property.
        let references = info.references?.map { String(describing: $0) }
            ?? info.additionalHeaderFields?.first { $0.name.lowercased() == "references" }
            .map { String(describing: $0.value) }
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) } ?? []
        return MailHeader(
            uid: uid.value,
            mailbox: mailbox,
            subject: info.subject?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "（无主题）",
            fromName: from?.name ?? "",
            fromAddress: from?.address ?? "",
            replyTo: info.replyToAddresses.mailboxes.first?.address,
            to: info.toAddresses.mailboxes.map(Self.display),
            cc: info.ccAddresses.mailboxes.map(Self.display),
            date: info.date ?? info.internalDate ?? .distantPast,
            seen: info.flags.contains(.seen),
            flagged: info.flags.contains(.flagged),
            answered: info.flags.contains(.answered),
            messageID: info.messageId.map { String(describing: $0) },
            references: references
        )
    }

    private static func display(_ a: EmailAddress) -> String {
        if let name = a.name, !name.isEmpty { return "\(name) <\(a.address)>" }
        return a.address
    }

    func body(uid: UInt32, in mailbox: String) async throws -> MailBody {
        try await withServer { server in
            _ = try await select(mailbox, on: server)
            let raw = try await server.fetchRawMessage(identifier: SwiftMail.UID(uid), timeoutSeconds: 60)
            let message = try EMLParser.parse(raw)
            var html = message.htmlBody
            // Inline images referenced as cid: become data: URLs so the web view can show them.
            if var page = html {
                for part in message.cids {
                    guard let cid = part.contentId?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")),
                          let data = part.decodedData() ?? part.data else { continue }
                    page = page.replacingOccurrences(
                        of: "cid:\(cid)", with: "data:\(part.contentType);base64,\(data.base64EncodedString())")
                }
                html = page
            }
            let attachments = message.attachments.compactMap { part -> MailAttachment? in
                guard let data = part.decodedData() ?? part.data else { return nil }
                return MailAttachment(filename: part.suggestedFilename, contentType: part.contentType, data: data)
            }
            return MailBody(text: message.textBody, html: html, attachments: attachments)
        }
    }

    func setFlag(_ flag: Flag, _ on: Bool, uids: [UInt32], in mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        try await withServer { server in
            _ = try await select(mailbox, on: server)
            try await server.store(flags: [flag], on: Self.set(uids), operation: on ? .add : .remove)
        }
    }

    func move(uids: [UInt32], from mailbox: String, to destination: String) async throws {
        guard !uids.isEmpty else { return }
        try await withServer { server in
            _ = try await select(mailbox, on: server)
            _ = try await server.move(messages: Self.set(uids), to: destination)
        }
    }

    /// Permanently remove (used inside 废纸篓, or when the account has no trash folder).
    func expunge(uids: [UInt32], in mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        try await withServer { server in
            _ = try await select(mailbox, on: server)
            try await server.store(flags: [.deleted], on: Self.set(uids), operation: .add)
            try await server.expunge(messages: Self.set(uids))
        }
    }

    func appendSent(_ email: Email, to mailbox: String) async throws {
        try await withServer { server in
            _ = try await server.append(email: email, to: mailbox, flags: [.seen])
        }
    }

    private static func set(_ uids: [UInt32]) -> UIDSet {
        var set = UIDSet()
        for uid in uids { set.insert(SwiftMail.UID(uid)) }
        return set
    }

    // MARK: Sending

    func send(_ mail: OutgoingMail) async throws -> Email {
        var email = Email(
            sender: EmailAddress(name: account.senderName, address: account.email),
            recipients: mail.to.map { EmailAddress(address: $0) },
            ccRecipients: mail.cc.map { EmailAddress(address: $0) },
            subject: mail.subject,
            textBody: mail.body,
            attachments: mail.attachments.isEmpty ? nil : mail.attachments.map {
                Attachment(filename: $0.filename, mimeType: $0.contentType, data: $0.data)
            }
        )
        var headers: [String: String] = [:]
        if let reply = mail.inReplyTo { headers["In-Reply-To"] = reply }
        if !mail.references.isEmpty { headers["References"] = mail.references.joined(separator: " ") }
        if !headers.isEmpty { email.additionalHeaders = headers }

        if account.provider == .outlook {
            try await sendViaGraph(mail)
            return email
        }
        let smtp = SMTPServer(host: account.smtpHost, port: account.smtpPort)
        try await smtp.connect()
        do {
            switch account.auth {
            case .password:
                guard let secret = account.secret else { throw MailError.noSecret }
                try await smtp.login(username: account.email, password: secret)
            case .oauth:
                try await smtp.authenticateXOAUTH2(email: account.email, accessToken: OAuthClient.accessToken(for: account))
            }
            _ = try await smtp.sendEmail(email)
        } catch {
            try? await smtp.disconnect()
            throw error
        }
        try? await smtp.disconnect()
        return email
    }

    /// Outlook.com no longer accepts SMTP AUTH; Microsoft Graph sends and files the copy in 已发送.
    private func sendViaGraph(_ mail: OutgoingMail) async throws {
        let token = try await OAuthClient.graphToken(for: account)
        func recipients(_ list: [String]) -> [[String: Any]] {
            list.map { ["emailAddress": ["address": $0]] }
        }
        var message: [String: Any] = [
            "subject": mail.subject,
            "body": ["contentType": "Text", "content": mail.body],
            "toRecipients": recipients(mail.to),
            "ccRecipients": recipients(mail.cc),
        ]
        if !mail.attachments.isEmpty {
            message["attachments"] = mail.attachments.map { a -> [String: Any] in
                ["@odata.type": "#microsoft.graph.fileAttachment", "name": a.filename,
                 "contentType": a.contentType, "contentBytes": a.data.base64EncodedString()]
            }
        }
        let payload: [String: Any] = ["message": message, "saveToSentItems": true]
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/sendMail")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MailError.send(String(decoding: data, as: UTF8.self))
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
