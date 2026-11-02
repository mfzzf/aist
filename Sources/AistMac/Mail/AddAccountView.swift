import AistCore
import AppKit
import SwiftUI

/// "添加账户", laid out like Mail's: type an address and continue (aist recognizes the service),
/// or pick a provider. Gmail / Outlook then sign in through the browser; the rest ask for an
/// authorization code / app password, with a link to where to get one.
struct AddAccountView: View {
    @ObservedObject var mail: MailCenter
    let onAdded: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case start
        case credentials(MailProvider)
    }

    @State private var step: Step = .start
    @State private var email = ""
    @State private var secret = ""
    @State private var senderName = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var working = false
    @State private var error: String?
    @FocusState private var emailFocused: Bool

    private var emailValid: Bool {
        let parts = email.trimmingCharacters(in: .whitespaces).split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .start: start
            case let .credentials(provider): credentials(provider)
            }
            Divider()
            footer
        }
        .frame(width: 500)
        .animation(.default, value: step)
    }

    // MARK: Step 1

    private var start: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加账户")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

            Text("输入电子邮件地址").font(.headline)
            TextField("user@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($emailFocused)
                .onSubmit { if emailValid { proceed(with: MailProvider.detect(email)) } }
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                        .lineLimit(3)
                }
                Spacer()
                Button("继续") { proceed(with: MailProvider.detect(email)) }
                    .disabled(!emailValid || working)
            }

            HStack {
                VStack { Divider() }
                Text("或").font(.callout).foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .padding(.vertical, 2)

            Text("选择提供商").font(.headline)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(MailProvider.listed.enumerated()), id: \.element) { index, provider in
                        if index > 0 { Divider().padding(.horizontal, 14) }
                        ProviderRow { ProviderMark(provider: provider) } action: { proceed(with: provider) }
                    }
                    Divider().padding(.horizontal, 14)
                    ProviderRow {
                        Text("其他邮件账户…").font(.title3)
                    } action: { proceed(with: .custom) }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quinary))
            }
            .frame(height: 380)
            .disabled(working)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .onAppear { emailFocused = true }
    }

    /// Route to the right sign-in for a provider (picked, or detected from the address).
    private func proceed(with provider: MailProvider) {
        error = nil
        if let service = provider.oauth {
            if OAuthClient.isConfigured(service) {
                Task { await signIn(provider, service) }
                return
            }
            if provider == .outlook {
                error = OAuthError.notConfigured(service).localizedDescription
                return
            }
        }
        if provider == .custom {
            let guess = MailProvider.guessServers(for: email)
            if imapHost.isEmpty { imapHost = guess.imap }
            if smtpHost.isEmpty { smtpHost = imapHost }
        }
        secret = ""
        step = .credentials(provider)
    }

    // MARK: Step 2

    private func credentials(_ provider: MailProvider) -> some View {
        Form {
            Section {
                LabeledContent("邮箱服务") {
                    if provider == .custom {
                        Text(provider.name)
                    } else {
                        ProviderMark(provider: provider).scaleEffect(0.7, anchor: .trailing).frame(height: 26)
                    }
                }
                TextField("邮箱地址", text: $email, prompt: Text("name@example.com"))
                SecureField(provider.secretName, text: $secret)
                TextField("发件人名称", text: $senderName, prompt: Text("可选"))
            } footer: {
                if !provider.secretHelp.isEmpty || provider.secretHelpURL != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(provider.secretHelp).foregroundStyle(.secondary)
                        if let url = provider.secretHelpURL {
                            Link(destination: url) {
                                Label(Self.helpLinkTitle(provider), systemImage: "arrow.up.forward.square")
                            }
                        }
                    }
                }
            }
            if provider == .custom {
                Section("服务器") {
                    TextField("IMAP 服务器", text: $imapHost, prompt: Text("mail.example.com"))
                        .onChange(of: imapHost) { old, new in
                            // SMTP is usually the same host (mail.xxx.sg) — follow until edited separately.
                            if smtpHost.isEmpty || smtpHost == old { smtpHost = new }
                        }
                    TextField("IMAP 端口", text: $imapPort)
                    TextField("SMTP 服务器", text: $smtpHost, prompt: Text("默认与 IMAP 服务器相同"))
                    TextField("SMTP 端口", text: $smtpPort)
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func canAdd(_ provider: MailProvider) -> Bool {
        guard emailValid, !secret.isEmpty else { return false }
        if provider == .custom {
            return !imapHost.isEmpty && !smtpHost.isEmpty && Int(imapPort) != nil && Int(smtpPort) != nil
        }
        return true
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if case .credentials = step {
                Button("返回") {
                    error = nil
                    step = .start
                }
            }
            if working { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if case let .credentials(provider) = step {
                Button("登录") { Task { await addWithPassword(provider) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd(provider) || working)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private static func helpLinkTitle(_ provider: MailProvider) -> String {
        switch provider {
        case .gmail, .yahoo, .aol, .zoho: "生成应用专用密码"
        case .icloud: "生成 App 专用密码"
        case .yandex: "生成应用密码"
        default: "打开\(provider.name)网页版，生成\(provider.secretName)"
        }
    }

    // MARK: Adding

    private func isDuplicate(_ address: String) -> Bool {
        mail.accounts.accounts.contains { $0.email.caseInsensitiveCompare(address) == .orderedSame }
    }

    private func addWithPassword(_ provider: MailProvider) async {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard !isDuplicate(address) else {
            error = "这个邮箱已经添加过了"
            return
        }
        let imap = provider.imap ?? (imapHost.trimmingCharacters(in: .whitespaces), Int(imapPort) ?? 993)
        let smtp = provider.smtp ?? (smtpHost.trimmingCharacters(in: .whitespaces), Int(smtpPort) ?? 465)
        let account = MailAccount(
            provider: provider, email: address, senderName: senderName.nonEmpty,
            imapHost: imap.host, imapPort: imap.port, smtpHost: smtp.host, smtpPort: smtp.port, auth: .password
        )
        await add(account, secret: secret.replacingOccurrences(of: " ", with: ""))
    }

    private func signIn(_ provider: MailProvider, _ service: OAuthService) async {
        error = nil
        working = true
        defer { working = false }
        do {
            let client = try OAuthClient.configured(service)
            let hint = MailProvider.detect(email) == provider ? email : nil
            let (address, tokens) = try await client.signIn(loginHint: hint)
            guard !isDuplicate(address) else {
                error = "这个邮箱已经添加过了"
                return
            }
            let imap = provider.imap!, smtp = provider.smtp!
            let account = MailAccount(
                provider: provider, email: address,
                imapHost: imap.host, imapPort: imap.port, smtpHost: smtp.host, smtpPort: smtp.port, auth: .oauth
            )
            await add(account, secret: String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self))
        } catch OAuthError.cancelled {
            return
        } catch {
            self.error = MailCenter.describe(error)
        }
    }

    private func add(_ account: MailAccount, secret: String) async {
        error = nil
        working = true
        defer { working = false }
        do {
            try await mail.add(account, secret: secret)
            onAdded(account.id)
            dismiss()
        } catch {
            self.error = MailCenter.describe(error)
        }
    }
}

/// A full-width provider row with a hover highlight.
private struct ProviderRow<Label: View>: View {
    @ViewBuilder let label: Label
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(hovered ? Color.primary.opacity(0.05) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Typographic wordmarks in each service's colors (no bundled logo artwork).
struct ProviderMark: View {
    let provider: MailProvider

    var body: some View {
        switch provider {
        case .icloud:
            HStack(spacing: 6) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0x6CC4F5), Color(hex: 0x2F7CF6)],
                                                    startPoint: .top, endPoint: .bottom))
                Text("iCloud").font(.system(size: 28, weight: .medium))
            }
        case .outlook:
            Text("Outlook.com").font(.system(size: 26, weight: .regular)).foregroundStyle(Color(hex: 0x0078D4))
        case .gmail:
            HStack(spacing: 0) {
                ForEach(Array(zip("Google", [0x4285F4, 0xEA4335, 0xFBBC05, 0x4285F4, 0x34A853, 0xEA4335]).enumerated()),
                        id: \.offset) { _, pair in
                    Text(String(pair.0)).foregroundStyle(Color(hex: UInt32(pair.1)))
                }
            }
            .font(.system(size: 28, weight: .medium))
        case .yahoo:
            Text("yahoo!").font(.system(size: 28, weight: .black)).italic().foregroundStyle(Color(hex: 0x6001D2))
        case .aol:
            Text("Aol.").font(.system(size: 30, weight: .black))
        case .qq:
            netease("QQ", 0x12B7F5, "QQ 邮箱", "mail.qq.com")
        case .netease163:
            netease("163", 0xD80000, "网易免费邮", "mail.163.com")
        case .netease126:
            netease("126", 0x0E8A3E, "网易免费邮", "www.126.com")
        case .yeah:
            netease("yeah", 0x1C64C8, "网易免费邮", "www.yeah.net")
        case .sina:
            netease("新浪", 0xE6162D, "新浪邮箱", "mail.sina.com.cn")
        case .sohu:
            netease("搜狐", 0xF5B800, "搜狐闪电邮箱", "mail.sohu.com")
        case .aliyun:
            netease("阿里", 0xFF6A00, "阿里邮箱", "mail.aliyun.com")
        case .mobile139:
            netease("139", 0x0085D0, "移动邮箱", "mail.10086.cn")
        case .exmail:
            netease("腾讯", 0x0052D9, "企业邮箱", "exmail.qq.com")
        case .qiye163:
            netease("网易", 0xD80000, "企业邮箱", "qiye.163.com")
        case .yandex:
            HStack(spacing: 0) {
                Text("Y").foregroundStyle(Color(hex: 0xFC3F1D))
                Text("andex")
            }
            .font(.system(size: 28, weight: .bold))
        case .zoho:
            Text("Zoho Mail").font(.system(size: 26, weight: .semibold)).foregroundStyle(Color(hex: 0xE42527))
        case .custom:
            Text(provider.name).font(.title3)
        }
    }

    /// The style Chinese webmail uses: a big colored mark, then name and address stacked.
    private func netease(_ mark: String, _ color: UInt32, _ title: String, _ host: String) -> some View {
        HStack(spacing: 6) {
            Text(mark)
                .font(.system(size: 30, weight: .heavy))
                .italic(mark.allSatisfy(\.isNumber))
                .foregroundStyle(Color(hex: color))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary.opacity(0.8))
                Text(host).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
