import Foundation
import Security

/// Generic-password items in the login keychain, scoped to Pulse.
public enum Keychain {
    public static let service = "dk.hlvm.pulse"
    /// The service Pulse 1.0–1.1 used, before the bundle identifier changed.
    static let legacyService = "dev.pulse.Pulse"

    public enum Account {
        public static let cliproxyKey = "cliproxyapi-management-key"
        public static let t3Token = "t3code-mcp-token"
    }

    public static func read(_ account: String) -> String? {
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
    public static func write(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Moves items saved under the old service name to the current one, once.
    /// Items already present under the current service are left alone.
    public static func migrateLegacyItems() {
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(listQuery as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return }
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            let itemQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
            ]
            var dataQuery = itemQuery
            dataQuery[kSecReturnData as String] = true
            dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var data: AnyObject?
            guard SecItemCopyMatching(dataQuery as CFDictionary, &data) == errSecSuccess,
                  let value = (data as? Data).flatMap({ String(data: $0, encoding: .utf8) })
            else { continue }
            if read(account) == nil, !write(value, account: account) { continue }
            SecItemDelete(itemQuery as CFDictionary)
        }
    }

    public static func readT3Token(account: String = Account.t3Token) -> T3Token? {
        guard let json = read(account) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T3Token.self, from: Data(json.utf8))
    }

    public static func writeT3Token(_ token: T3Token, account: String = Account.t3Token) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(token) else { return }
        write(String(decoding: data, as: UTF8.self), account: account)
    }
}
