import Foundation
import Security

/// Minimal generic-password wrapper. Reads are cached for the process: every keychain read can
/// put up an authorisation prompt (and blocks its thread while it's up), so each item is read
/// once per launch, not once per mail or per connection. Writes and deletes drop the cache.
public enum KeychainStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    public static func read(service: String, account: String = "default") -> String? {
        let key = service + "\u{1}" + account
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let value = readUncached(service: service, account: account)
        lock.lock(); cache[key] = value; lock.unlock()
        return value
    }

    private static func forget(service: String, account: String) {
        lock.lock(); cache[service + "\u{1}" + account] = nil; lock.unlock()
    }

    private static func readUncached(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(service: String, account: String = "default") -> Bool {
        forget(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    public static func write(_ value: String, service: String, account: String = "default") -> Bool {
        forget(service: service, account: account)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
