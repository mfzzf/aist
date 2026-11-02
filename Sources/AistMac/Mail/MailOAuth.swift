import AistCore
import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Network

/// The OAuth token bundle kept in the Keychain for an OAuth mail account.
struct OAuthTokens: Codable, Sendable {
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
}

enum OAuthError: LocalizedError {
    case notConfigured(OAuthService)
    case cancelled
    case badResponse(String)
    case noEmail
    case signedOut

    var errorDescription: String? {
        switch self {
        case .notConfigured(.google):
            "还没有配置 Google 登录：在 ~/.config/aist/config.json 里填写 googleClientID"
        case .notConfigured(.microsoft):
            "还没有配置微软登录：在 ~/.config/aist/config.json 里填写 microsoftClientID"
        case .cancelled: "登录已取消"
        case let .badResponse(text): "登录失败：\(text.prefix(200))"
        case .noEmail: "没能从登录结果里拿到邮箱地址"
        case .signedOut: "登录已失效，请删除这个账户后重新添加"
        }
    }
}

/// Browser sign-in (authorization code + PKCE, no client secret) for Gmail and Outlook,
/// and access-token refresh for IMAP / SMTP XOAUTH2.
///
/// Client IDs come from `~/.config/aist/config.json`:
/// - `googleClientID` (+ `googleClientSecret`): a Google Cloud OAuth client of type **Desktop app**.
///   Sign-in opens the default browser and catches the redirect on a one-shot loopback port
///   (http://127.0.0.1:<port>), Google's recommended flow for installed apps — no server needed.
///   An **iOS**-type client (no secret) also works, via `com.googleusercontent.apps.<id>:/oauth2redirect`.
/// - `microsoftClientID`: a Microsoft Entra app, "Mobile and desktop" platform, redirect
///   `msauth.com.jianfengmei.aist://auth`, accounts in any org directory + personal Microsoft accounts.
struct OAuthClient: Sendable {
    let service: OAuthService
    let clientID: String
    /// Desktop-type clients have one; Google says it isn't treated as confidential for installed apps.
    let clientSecret: String?

    static func configured(_ service: OAuthService) throws -> OAuthClient {
        let prefix = service == .google ? "google" : "microsoft"
        guard let data = try? Data(contentsOf: LLMConfig.fileURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = dict[prefix + "ClientID"] as? String, !id.isEmpty
        else { throw OAuthError.notConfigured(service) }
        let secret = (dict[prefix + "ClientSecret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return OAuthClient(service: service, clientID: id, clientSecret: secret)
    }

    /// Desktop clients redirect to a loopback port in the default browser instead of a custom scheme.
    private var usesLoopback: Bool { service == .google && clientSecret != nil }

    static func isConfigured(_ service: OAuthService) -> Bool { (try? configured(service)) != nil }

    private var authorizeURL: URL {
        switch service {
        case .google: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .microsoft: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        }
    }

    private var tokenURL: URL {
        switch service {
        case .google: URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        }
    }

    /// IMAP + SMTP (and for Microsoft, Graph Mail.Send: Outlook.com no longer allows SMTP AUTH).
    private var scopes: String {
        switch service {
        case .google:
            "https://mail.google.com/ openid email"
        case .microsoft:
            "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access openid email"
        }
    }

    static let graphSendScope = "https://graph.microsoft.com/Mail.Send offline_access"

    private var callbackScheme: String {
        switch service {
        case .google:
            // "1234-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abc"
            "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        case .microsoft:
            "msauth.com.jianfengmei.aist"
        }
    }

    private var redirectURI: String {
        switch service {
        case .google: callbackScheme + ":/oauth2redirect"
        case .microsoft: callbackScheme + "://auth"
        }
    }

    // MARK: Sign in

    @MainActor
    func signIn(loginHint: String? = nil) async throws -> (email: String, tokens: OAuthTokens) {
        var loopback: LoopbackReceiver?
        var redirectURI = self.redirectURI
        if usesLoopback {
            let receiver = try LoopbackReceiver()
            redirectURI = "http://127.0.0.1:\(try await receiver.start())"
            loopback = receiver
        }
        defer { loopback?.stop() }
        let verifier = Self.randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(16)

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        switch service {
        case .google:
            query += [URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent")]
        case .microsoft:
            query += [URLQueryItem(name: "prompt", value: "select_account")]
        }
        if let loginHint, !loginHint.isEmpty { query.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = query

        let callback: URL
        if let loopback {
            NSWorkspace.shared.open(components.url!)
            callback = try await loopback.callback()
            NSApp.activate()
        } else {
            callback = try await WebAuth.run(url: components.url!, scheme: callbackScheme)
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let detail = items.first(where: { $0.name == "error_description" })?.value ?? ""
            throw OAuthError.badResponse("\(error) \(detail)")
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw OAuthError.badResponse("回调缺少授权码") }

        let response = try await post([
            "client_id": clientID,
            "client_secret": clientSecret ?? "",
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        guard let refresh = response.refreshToken else { throw OAuthError.badResponse("没有返回 refresh token") }
        guard let email = response.idToken.flatMap(Self.email(fromIDToken:)) else { throw OAuthError.noEmail }
        return (email, OAuthTokens(refreshToken: refresh, accessToken: response.accessToken,
                                   expiresAt: .now.addingTimeInterval(response.expiresIn - 60)))
    }

    // MARK: Tokens

    /// A valid IMAP/SMTP access token for the account, refreshed (and re-saved) when expired.
    static func accessToken(for account: MailAccount) async throws -> String {
        guard let service = account.provider.oauth else { throw OAuthError.signedOut }
        guard let json = account.secret, var tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
        else { throw OAuthError.signedOut }
        if tokens.expiresAt > .now { return tokens.accessToken }
        let client = try configured(service)
        let response = try await client.post([
            "client_id": client.clientID,
            "client_secret": client.clientSecret ?? "",
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ])
        tokens.accessToken = response.accessToken
        tokens.expiresAt = .now.addingTimeInterval(response.expiresIn - 60)
        if let rotated = response.refreshToken { tokens.refreshToken = rotated }
        if let data = try? JSONEncoder().encode(tokens) { account.storeSecret(String(decoding: data, as: UTF8.self)) }
        return tokens.accessToken
    }

    /// A Microsoft Graph token (Mail.Send) minted from the same refresh token.
    static func graphToken(for account: MailAccount) async throws -> String {
        guard let json = account.secret, var tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
        else { throw OAuthError.signedOut }
        let client = try configured(.microsoft)
        let response = try await client.post([
            "client_id": client.clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "scope": graphSendScope,
        ])
        if let rotated = response.refreshToken {
            tokens.refreshToken = rotated
            if let data = try? JSONEncoder().encode(tokens) { account.storeSecret(String(decoding: data, as: UTF8.self)) }
        }
        return response.accessToken
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double
        var idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }

    private func post(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.filter { !$0.value.isEmpty }.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else { throw OAuthError.badResponse(String(decoding: data, as: UTF8.self)) }
        return decoded
    }

    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return (claims["email"] as? String) ?? (claims["preferred_username"] as? String)
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The system's web sign-in sheet (shares cookies with Safari, so an already-signed-in account is one click).
@MainActor
private final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private static var running: WebAuth?

    static func run(url: URL, scheme: String) async throws -> URL {
        let auth = WebAuth()
        running = auth
        defer { running = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.cancelled)
                }
            }
            session.presentationContextProvider = auth
            session.prefersEphemeralWebBrowserSession = false
            auth.session = session
            if !session.start() { continuation.resume(throwing: OAuthError.badResponse("无法打开登录窗口")) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow() }
    }
}

/// One-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect from the browser.
private final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "aist.oauth.loopback")
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    /// Touched only on `queue`.
    private var readyReported = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening; returns the port the system picked.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [self] state in
                guard !readyReported else { return }
                switch state {
                case .ready:
                    readyReported = true
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    readyReported = true
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits (up to 5 minutes) for the browser to come back with ?code=… or ?error=….
    func callback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result {
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                }
            }
            queue.asyncAfter(deadline: .now() + 300) { self.finish(.failure(OAuthError.cancelled)) }
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "GET /?code=…&state=… HTTP/1.1"
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let url = URL(string: "http://127.0.0.1" + target)
            let isCallback = target.contains("code=") || target.contains("error=")
            let page = isCallback
                ? "<h2 style='font:-apple-system-title2;text-align:center;margin-top:20vh'>已完成登录，可以回到 Aist 了。</h2>"
                : ""
            let body = Data("<!doctype html><meta charset=utf-8><title>Aist</title>\(page)".utf8)
            var response = Data("HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            if isCallback, let url { self.finish(.success(url)) }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
