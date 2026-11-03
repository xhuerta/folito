import Foundation
import Security
import ReaderCore

/// Thin generic-password Keychain wrapper (no access groups; free Personal Team friendly).
enum KeychainStore {
    private static let service = "folito.kosync"

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

/// The active connector's credentials in the watch Keychain, one item per storage key. Connectors write
/// rotated tokens (Readest) through it.
struct KeychainCredentialStore: SyncCredentialStore {
    let keys: [String]

    func load() -> SyncCredentials? {
        var values: [String: String] = [:]
        for key in keys { if let v = KeychainStore.get(key) { values[key] = v } }
        return values.isEmpty ? nil : SyncCredentials(values)
    }

    func save(_ credentials: SyncCredentials?) {
        for key in keys { KeychainStore.set(credentials?[key], for: key) }
    }
}

/// Progress-sync settings received from the phone: which connector is active and its credentials,
/// stored in the watch Keychain. Wire format: docs/WATCH_CONNECTIVITY.md (generic `sync_connector` +
/// `sync_credentials`, plus the KOSync-only keys sent by older phone builds).
enum CredentialsStore {
    /// KOSync storage keys (unchanged since the first release, so upgraded watches keep their login).
    enum Key {
        static let server = KOSyncConnectorFactory.Key.server
        static let user = KOSyncConnectorFactory.Key.user
        static let password = KOSyncConnectorFactory.Key.password
    }

    /// Keychain account holding the active connector id.
    static let connectorAccount = "sync_connector"

    static var registry: SyncConnectorRegistry { .standard }

    /// The active connector id; builds from before connectors only stored KOSync keys.
    static var activeConnectorID: String? {
        if let id = KeychainStore.get(connectorAccount), registry.factory(id: id) != nil { return id }
        return KeychainStore.get(Key.user) != nil ? KOSyncConnectorFactory.id : nil
    }

    static var activeFactory: SyncConnectorFactory? { activeConnectorID.flatMap(registry.factory(id:)) }

    static var activeCredentials: SyncCredentials? {
        guard let f = activeFactory else { return nil }
        return KeychainCredentialStore(keys: f.descriptor.storageKeys).load()
    }

    /// Account shown in Settings (user name or email).
    static var username: String? {
        guard let f = activeFactory, let c = activeCredentials else { return nil }
        return f.accountLabel(for: c)
    }

    /// Localized-free display name of the active service (the view localizes it).
    static var activeServiceName: String? { activeFactory?.descriptor.displayName }

    /// KOSync credentials when KOSync is the active connector (kept for existing callers and tests).
    static func current() -> KOSyncCredentials? {
        guard activeConnectorID == KOSyncConnectorFactory.id else { return nil }
        return ServerURL.credentials(server: KeychainStore.get(Key.server),
                                     user: KeychainStore.get(Key.user),
                                     password: KeychainStore.get(Key.password))
    }

    // MARK: Connector cache

    private static let lock = NSLock()
    private static var generation = 0
    private static var cached: (generation: Int, connector: SyncConnector)?

    /// The connector for the stored credentials, or nil when sync is off. Rebuilt only when the phone sends
    /// new settings (or they are cleared), so a Readest session refresh is shared by concurrent requests.
    static func activeConnector() -> SyncConnector? {
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.generation == generation { return cached.connector }
        guard let f = activeFactory else { cached = nil; return nil }
        let store = KeychainCredentialStore(keys: f.descriptor.storageKeys)
        guard let creds = store.load() else { cached = nil; return nil }
        if f.descriptor.id == KOSyncConnectorFactory.id, current() == nil { cached = nil; return nil }
        let connector = f.makeConnector(credentials: creds, store: store, session: .shared)
        cached = (generation, connector)
        return connector
    }

    private static func invalidate() {
        lock.lock(); generation += 1; cached = nil; lock.unlock()
    }

    // MARK: Settings channel

    /// Phone -> watch "sync turned off" marker (see docs/WATCH_CONNECTIVITY.md).
    static let clearedKey = "kosync_cleared"

    static func isClearRequest(_ userInfo: [String: Any]) -> Bool {
        (userInfo[clearedKey] as? Bool) == true || (userInfo[SyncSettingsWire.clearedKey] as? Bool) == true
    }

    /// True when the dictionary carries progress-sync settings (generic or KOSync-only keys).
    static func hasSyncSettings(_ info: [String: Any]) -> Bool {
        info[SyncSettingsWire.connectorKey] != nil || info[Key.server] != nil || info[Key.user] != nil
            || info[Key.password] != nil || isClearRequest(info)
    }

    /// Applies a dictionary from the settings channel. An explicit cleared marker wins and removes everything;
    /// generic connector keys replace all stored credentials; legacy KOSync keys update only the keys present.
    /// Returns true when anything changed.
    @discardableResult
    static func apply(userInfo: [String: Any]) -> Bool {
        if isClearRequest(userInfo) { clear(); return true }
        if let decoded = SyncSettingsWire.decode(userInfo), let f = registry.factory(id: decoded.0) {
            for key in registry.allStorageKeys { KeychainStore.set(nil, for: key) }
            KeychainCredentialStore(keys: f.descriptor.storageKeys).save(decoded.1)
            KeychainStore.set(decoded.0, for: connectorAccount)
            invalidate()
            return true
        }
        var changed = false
        for key in [Key.server, Key.user, Key.password] {
            if let value = userInfo[key] as? String {
                KeychainStore.set(value, for: key)
                changed = true
            }
        }
        if changed {
            if activeConnectorID != KOSyncConnectorFactory.id {
                for key in registry.allStorageKeys where ![Key.server, Key.user, Key.password].contains(key) {
                    KeychainStore.set(nil, for: key)
                }
            }
            KeychainStore.set(KOSyncConnectorFactory.id, for: connectorAccount)
            invalidate()
        }
        return changed
    }

    static func clear() {
        for key in registry.allStorageKeys { KeychainStore.set(nil, for: key) }
        KeychainStore.set(nil, for: connectorAccount)
        invalidate()
    }
}
