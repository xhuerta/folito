import Foundation
import Security

/// Minimal generic-password Keychain wrapper. No access groups (free Personal Team).
struct KeychainStore {
    var service: String = "com.xlahuerta.folito.kosync"
    #if DEBUG
    /// UI testing only (`UITesting.makeSyncSettings`): items live in memory. The simulator builds that CI tests
    /// are not code-signed, so the real Keychain refuses them and a mocked sign-in would not be kept.
    var memory: MemoryKeychain? = nil
    #endif

    func set(_ value: String, account: String) throws {
        #if DEBUG
        if let memory { memory.set(value, account: account); return }
        #endif
        let data = Data(value.utf8)
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    func get(account: String) -> String? {
        #if DEBUG
        if let memory { return memory.get(account) }
        #endif
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(account: String) {
        #if DEBUG
        if let memory { memory.set(nil, account: account); return }
        #endif
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum KeychainError: Error { case status(OSStatus) }

#if DEBUG
/// In-memory stand-in for the Keychain (see `KeychainStore.memory`).
final class MemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    func set(_ value: String?, account: String) {
        lock.lock(); defer { lock.unlock() }
        items[account] = value
    }

    func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }
}
#endif
