import Foundation
import Security

/// Generic-password items under one service. Accounts: "<server>/<user>" for DB passwords,
/// "token/<agent>" for agent bearer tokens.
enum Keychain {
    // Overridable so tests don't touch real items.
    static let service = ProcessInfo.processInfo.environment["DB_PROXY_KEYCHAIN_SERVICE"] ?? "db-proxy"

    private static func base(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    static func get(_ account: String) throws -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        try check(status, "read \(account)")
        return (out as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    static func set(_ account: String, _ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = base(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "\(service): \(account)"
            try check(SecItemAdd(q as CFDictionary, nil), "add \(account)")
        } else {
            try check(status, "update \(account)")
        }
    }

    /// Returns false if the item did not exist.
    static func delete(_ account: String) throws -> Bool {
        let status = SecItemDelete(base(account) as CFDictionary)
        if status == errSecItemNotFound { return false }
        try check(status, "delete \(account)")
        return true
    }

    static func accounts() throws -> [String] {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        try check(status, "list items")
        return ((out as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// token -> agent name, for every "token/<agent>" item.
    static func agentTokens() throws -> [String: String] {
        var map: [String: String] = [:]
        for account in try accounts() where account.hasPrefix("token/") {
            if let token = try get(account) { map[token] = String(account.dropFirst("token/".count)) }
        }
        return map
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == errSecSuccess else {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw ConfigError("keychain: cannot \(what): \(msg)")
        }
    }
}
