import Foundation
import Security
import ReaderCore

/// Thin generic-password Keychain wrapper (no access groups; free Personal Team friendly).
enum KeychainStore {
    private static let service = "wristreader.kosync"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`; nil or empty deletes the item.
    static func set(_ value: String?, for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}

/// KOReader Sync settings received from the phone, stored in the watch Keychain.
enum CredentialsStore {
    enum Key {
        static let server = "kosync_server"
        static let user = "kosync_user"
        static let password = "kosync_password"
    }

    static var serverString: String? { KeychainStore.get(Key.server) }
    static var username: String? { KeychainStore.get(Key.user) }

    static func current() -> KOSyncCredentials? {
        ServerURL.credentials(server: KeychainStore.get(Key.server),
                              user: KeychainStore.get(Key.user),
                              password: KeychainStore.get(Key.password))
    }

    /// Applies a dictionary from `transferUserInfo`; only keys that are present are updated.
    /// Returns true when anything changed.
    @discardableResult
    static func apply(userInfo: [String: Any]) -> Bool {
        var changed = false
        for key in [Key.server, Key.user, Key.password] {
            if let value = userInfo[key] as? String {
                KeychainStore.set(value, for: key)
                changed = true
            }
        }
        return changed
    }

    static func clear() {
        for key in [Key.server, Key.user, Key.password] { KeychainStore.set(nil, for: key) }
    }
}
