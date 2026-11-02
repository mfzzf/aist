import Foundation

/// Names the user goes by, handed to the AI so "@张三" / "Alex" / "alex.zhang@…" are recognised as the user:
/// what they typed in 设置 › 通用 › 你的名字, plus mail sender names and addresses, and the GitHub login.
enum UserIdentity {
    static let namesKey = "profile.names"

    /// What the user typed, comma/space separated ("张三, Alex Zhang").
    static var typed: String {
        get { UserDefaults.standard.string(forKey: namesKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: namesKey) }
    }

    /// Kept up to date by AppDelegate from the mail accounts and GitHub.
    @MainActor static var discovered: [String] = []

    @MainActor static var names: [String] {
        let mine = typed.split(whereSeparator: { ",，、;；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var seen = Set<String>()
        return (mine + discovered).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func from(email: String, senderName: String?) -> [String] {
        var out: [String] = []
        if let senderName, !senderName.isEmpty { out.append(senderName) }
        out.append(email)
        if let local = email.split(separator: "@").first, local.count > 2, !local.allSatisfy(\.isNumber) {
            out.append(String(local))
        }
        return out
    }
}
