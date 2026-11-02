import Combine
import Foundation

/// Mail services aist knows how to set up in one step.
/// Servers and sign-in rules per provider; anything else falls back to `custom` with guessed hosts.
public enum MailProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case icloud, outlook, gmail, yahoo, aol
    case qq, netease163, netease126, yeah, sina, sohu, aliyun, mobile139
    case exmail, qiye163, yandex, zoho
    case custom

    public var id: String { rawValue }

    /// Order shown in "选择提供商".
    public static let listed: [MailProvider] = [
        .icloud, .outlook, .gmail, .qq, .netease163, .netease126, .yeah, .sina, .sohu, .aliyun, .mobile139,
        .exmail, .qiye163, .yahoo, .aol, .yandex, .zoho,
    ]

    public var name: String {
        switch self {
        case .icloud: "iCloud 邮件"
        case .outlook: "Outlook"
        case .gmail: "Gmail"
        case .yahoo: "Yahoo"
        case .aol: "AOL"
        case .qq: "QQ 邮箱"
        case .netease163: "163 邮箱"
        case .netease126: "126 邮箱"
        case .yeah: "yeah.net 邮箱"
        case .sina: "新浪邮箱"
        case .sohu: "搜狐邮箱"
        case .aliyun: "阿里邮箱"
        case .mobile139: "139 邮箱"
        case .exmail: "腾讯企业邮"
        case .qiye163: "网易企业邮"
        case .yandex: "Yandex"
        case .zoho: "Zoho Mail"
        case .custom: "其他邮箱"
        }
    }

    /// Sign-in: OAuth in the browser, or an app password / authorization code.
    public var oauth: OAuthService? {
        switch self {
        case .gmail: .google
        case .outlook: .microsoft
        default: nil
        }
    }

    public var imap: (host: String, port: Int)? {
        switch self {
        case .icloud: ("imap.mail.me.com", 993)
        case .outlook: ("outlook.office365.com", 993)
        case .gmail: ("imap.gmail.com", 993)
        case .yahoo: ("imap.mail.yahoo.com", 993)
        case .aol: ("imap.aol.com", 993)
        case .qq: ("imap.qq.com", 993)
        case .netease163: ("imap.163.com", 993)
        case .netease126: ("imap.126.com", 993)
        case .yeah: ("imap.yeah.net", 993)
        case .sina: ("imap.sina.com", 993)
        case .sohu: ("imap.sohu.com", 993)
        case .aliyun: ("imap.aliyun.com", 993)
        case .mobile139: ("imap.139.com", 993)
        case .exmail: ("imap.exmail.qq.com", 993)
        case .qiye163: ("imap.qiye.163.com", 993)
        case .yandex: ("imap.yandex.com", 993)
        case .zoho: ("imap.zoho.com", 993)
        case .custom: nil
        }
    }

    public var smtp: (host: String, port: Int)? {
        switch self {
        case .icloud: ("smtp.mail.me.com", 587)
        case .outlook: ("smtp-mail.outlook.com", 587)
        case .gmail: ("smtp.gmail.com", 465)
        case .yahoo: ("smtp.mail.yahoo.com", 465)
        case .aol: ("smtp.aol.com", 465)
        case .qq: ("smtp.qq.com", 465)
        case .netease163: ("smtp.163.com", 465)
        case .netease126: ("smtp.126.com", 465)
        case .yeah: ("smtp.yeah.net", 465)
        case .sina: ("smtp.sina.com", 465)
        case .sohu: ("smtp.sohu.com", 465)
        case .aliyun: ("smtp.aliyun.com", 465)
        case .mobile139: ("smtp.139.com", 465)
        case .exmail: ("smtp.exmail.qq.com", 465)
        case .qiye163: ("smtp.qiye.163.com", 465)
        case .yandex: ("smtp.yandex.com", 465)
        case .zoho: ("smtp.zoho.com", 465)
        case .custom: nil
        }
    }

    /// What the password field is called for this service.
    public var secretName: String {
        switch self {
        case .qq, .netease163, .netease126, .yeah, .sina, .sohu, .mobile139: "授权码"
        case .exmail, .qiye163: "客户端专用密码"
        case .gmail, .icloud, .yahoo, .aol, .zoho: "应用专用密码"
        case .yandex: "应用密码"
        default: "密码"
        }
    }

    /// Where the user turns on IMAP and gets the authorization code / app password.
    public var secretHelpURL: URL? {
        let link: String? = switch self {
        case .icloud: "https://account.apple.com/account/manage/section/security"
        case .gmail: "https://myaccount.google.com/apppasswords"
        case .yahoo: "https://login.yahoo.com/account/security"
        case .aol: "https://login.aol.com/account/security"
        case .qq: "https://mail.qq.com/"
        case .netease163: "https://mail.163.com/"
        case .netease126: "https://mail.126.com/"
        case .yeah: "https://mail.yeah.net/"
        case .sina: "https://mail.sina.com.cn/"
        case .sohu: "https://mail.sohu.com/"
        case .aliyun: "https://mail.aliyun.com/"
        case .mobile139: "https://mail.10086.cn/"
        case .exmail: "https://exmail.qq.com/"
        case .qiye163: "https://qiye.163.com/login/"
        case .yandex: "https://id.yandex.com/security/app-passwords"
        case .zoho: "https://accounts.zoho.com/home#security/app_password"
        case .outlook, .custom: nil
        }
        return link.flatMap(URL.init(string:))
    }

    public var secretHelp: String {
        switch self {
        case .qq: "在 QQ 邮箱网页版：设置 › 账号与安全 › 安全设置，开启「IMAP/SMTP 服务」，按提示生成授权码。"
        case .netease163, .netease126, .yeah:
            "在网页版：设置 › POP3/SMTP/IMAP，开启「IMAP/SMTP 服务」，按提示生成客户端授权码。"
        case .sina: "在新浪邮箱网页版：设置 › 客户端 POP/IMAP/SMTP，开启 IMAP 服务并生成授权码。"
        case .sohu: "在搜狐邮箱网页版：设置 › POP3/SMTP/IMAP，开启 IMAP 服务并生成独立密码（授权码）。"
        case .aliyun: "在阿里邮箱网页版：设置 › 账户 › POP3/SMTP 及 IMAP，开启 IMAP 后用登录密码。"
        case .mobile139: "在 139 邮箱网页版：设置 › 客户端设置，开启 IMAP 服务并生成授权码。"
        case .exmail: "在腾讯企业邮网页版：设置 › 客户端设置，开启 IMAP/SMTP；开了微信安全登录的话，用「客户端专用密码」。"
        case .qiye163: "在网易企业邮网页版：设置 › 客户端设置，开启 IMAP；开了安全登录的话，用「客户端专用密码」。"
        case .gmail: "开启两步验证后，在 Google 账号 › 安全 › 应用专用密码 里生成一个 16 位密码。"
        case .icloud: "在 Apple 账户 › 登录与安全 › App 专用密码 里生成一个。"
        case .yahoo, .aol: "在账户安全设置里「生成应用密码」，选「其他应用」。"
        case .yandex: "在 Yandex ID › 安全 › 应用密码 里为「邮件」生成一个，并在邮箱设置里允许 IMAP。"
        case .zoho: "在 Zoho 账户 › 安全 › 应用专用密码 里生成一个，并在邮箱设置里开启 IMAP。"
        case .outlook, .custom: ""
        }
    }

    /// Guess the service from an address.
    public static func detect(_ email: String) -> MailProvider {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return .gmail
        case "outlook.com", "hotmail.com", "live.com", "msn.com", "outlook.cn", "live.cn", "hotmail.co.uk": return .outlook
        case "icloud.com", "me.com", "mac.com": return .icloud
        case "yahoo.com", "ymail.com", "rocketmail.com", "yahoo.co.uk", "yahoo.com.my", "yahoo.com.sg": return .yahoo
        case "aol.com": return .aol
        case "qq.com", "foxmail.com", "vip.qq.com": return .qq
        case "163.com", "vip.163.com": return .netease163
        case "126.com", "vip.126.com": return .netease126
        case "yeah.net": return .yeah
        case "sina.com", "sina.cn", "vip.sina.com": return .sina
        case "sohu.com", "vip.sohu.com": return .sohu
        case "aliyun.com": return .aliyun
        case "139.com": return .mobile139
        case "yandex.com", "yandex.ru", "ya.ru": return .yandex
        case "zoho.com", "zohomail.com": return .zoho
        default: return .custom
        }
    }

    /// Best guess for an unknown domain: imap.<domain>; SMTP defaults to the same host as IMAP in the form.
    public static func guessServers(for email: String) -> (imap: String, smtp: String) {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        return domain.isEmpty ? ("", "") : ("imap.\(domain)", "smtp.\(domain)")
    }

    /// Servers that file sent mail themselves; for the rest aist appends a copy to 已发送.
    public var savesSentCopy: Bool { self == .gmail || self == .outlook || self == .yahoo || self == .aol }
}

public enum OAuthService: String, Codable, Sendable { case google, microsoft }

public enum MailAuth: String, Codable, Sendable { case password, oauth }

public struct MailAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: MailProvider
    public var email: String
    /// Name shown to recipients.
    public var senderName: String?
    public var imapHost: String
    public var imapPort: Int
    public var smtpHost: String
    public var smtpPort: Int
    public var auth: MailAuth
    public var addedAt: Date

    public init(id: UUID = UUID(), provider: MailProvider, email: String, senderName: String? = nil,
                imapHost: String, imapPort: Int, smtpHost: String, smtpPort: Int, auth: MailAuth) {
        self.id = id
        self.provider = provider
        self.email = email
        self.senderName = senderName
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.auth = auth
        self.addedAt = .now
    }

    /// The password / authorization code, or the OAuth token bundle (JSON), lives in the Keychain.
    public static let keychainService = "com.aist.mail"
    public var secret: String? { KeychainStore.read(service: Self.keychainService, account: id.uuidString) }
    @discardableResult
    public func storeSecret(_ value: String) -> Bool {
        KeychainStore.write(value, service: Self.keychainService, account: id.uuidString)
    }
    public func deleteSecret() { KeychainStore.delete(service: Self.keychainService, account: id.uuidString) }
}

/// Mail accounts, persisted next to the to-dos (secrets in the Keychain).
@MainActor
public final class MailAccountStore: ObservableObject {
    @Published public private(set) var accounts: [MailAccount] = []
    private let fileURL: URL

    public init(fileURL: URL = MailAccountStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([MailAccount].self, from: data) {
            accounts = decoded
        }
    }

    public nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aist/mail", isDirectory: true)
    }

    public nonisolated static var defaultURL: URL { directory.appendingPathComponent("accounts.json") }

    public func account(_ id: UUID) -> MailAccount? { accounts.first { $0.id == id } }

    public func add(_ account: MailAccount) {
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        save()
    }

    public func remove(_ id: UUID) {
        account(id)?.deleteSecret()
        accounts.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(accounts).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("aist: failed to save mail accounts: \(error)")
        }
    }
}
