import Foundation
import ReaderCore

/// Pure validation of the user-entered KOSync form.
enum SyncSettingsValidator {
    static let defaultServer = KOSyncConnectorFactory.defaultServer

    static func credentials(server: String, user: String, password: String) -> KOSyncCredentials? {
        KOSyncConnectorFactory.credentials(server: server, user: user, password: password)
    }

    /// Warning shown while the URL uses plain `http://`; nil for https.
    static func insecureWarning(server: String) -> String? {
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.hasPrefix("http://"), let host = URL(string: s)?.host else { return nil }
        if isLocalHost(host) {
            return String(localized: "http:// is not encrypted. Use it only on your home network: the sync password hash and your reading progress are sent in clear.",
                          comment: "Warning under the server URL field")
        }
        return String(localized: "iOS blocks http:// connections to internet hosts, so this will fail. Use https://, or a local address (IP address, .local or a name without dots).",
                      comment: "Warning under the server URL field")
    }

    /// Hosts that `NSAllowsLocalNetworking` lets through over http: IP literals, `.local`, dotless names.
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || !h.contains(".") || h.contains(":") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    static func message(for error: Error) -> String { UserFacingError.syncMessage(for: error) }
}

/// Result of the last action in the Sync screen, shown inline and announced to VoiceOver.
struct SyncStatus: Equatable {
    enum Kind: Equatable { case success, failure, info }
    let kind: Kind
    let text: String

    static func success(_ text: String) -> SyncStatus { SyncStatus(kind: .success, text: text) }
    static func failure(_ text: String) -> SyncStatus { SyncStatus(kind: .failure, text: text) }
    static func info(_ text: String) -> SyncStatus { SyncStatus(kind: .info, text: text) }

    static var missingFields: SyncStatus {
        .failure(String(localized: "Enter your username and password. Leave the server URL empty to use the default server.",
                        comment: "Sync form validation message"))
    }

    static func missingFieldsStatus(for connectorID: String) -> SyncStatus {
        switch connectorID {
        case ReadestConnectorFactory.id:
            return .failure(String(localized: "Enter your Readest email and password.",
                                   comment: "Sync form validation message for Readest"))
        default:
            return missingFields
        }
    }
}

/// Progress-sync settings of the iPhone: which connector is active (None, KOReader Sync, Readest, ...),
/// its credentials in the Keychain, and what is mirrored to the watch. The screen is generated from
/// `SyncConnectorRegistry` (see docs/SYNC_CONNECTORS.md).
@MainActor
final class SyncSettings: ObservableObject {
    /// UserDefaults key of the active connector id (absent = sync off).
    static let connectorKey = "sync.connector"
    private static let stampKey = "settings.savedAt"
    private static let clearedKey = "settings.clearedAt"

    /// Connector chosen in the picker ("" = None). Changing it loads that connector's form.
    @Published var selectedConnectorID: String {
        didSet { if oldValue != selectedConnectorID { loadForm() } }
    }
    /// Sign-in form of the selected connector, keyed by `CredentialField.key`.
    @Published var fields: [String: String] = [:]
    @Published var status: SyncStatus?
    @Published var isBusy = false
    /// Connector whose credentials are saved; sync is ON only then. The prefilled default server or unsaved
    /// text in the form never counts.
    @Published private(set) var activeConnectorID: String? = nil

    let registry: SyncConnectorRegistry
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let session: URLSession
    private let makeConnector: (SyncConnectorFactory, SyncCredentials) -> SyncConnector
    var onSave: ((SyncCredentials) -> Void)?
    var onTurnOff: (() -> Void)?

    var isSyncOn: Bool { activeConnectorID != nil }

    init(keychain: KeychainStore = KeychainStore(), defaults: UserDefaults = .standard,
         registry: SyncConnectorRegistry = .standard, session: URLSession = .shared,
         makeConnector: ((SyncConnectorFactory, SyncCredentials) -> SyncConnector)? = nil) {
        self.keychain = keychain
        self.defaults = defaults
        self.registry = registry
        self.session = session
        self.makeConnector = makeConnector ?? { factory, creds in
            factory.makeConnector(credentials: creds, store: InMemoryCredentialStore(creds), session: session)
        }
        selectedConnectorID = ""
        Self.migrateLegacyKeychain(keychain, defaults: defaults)
        activeConnectorID = Self.loadActiveID(keychain: keychain, defaults: defaults, registry: registry)
        selectedConnectorID = activeConnectorID ?? ""
        loadForm()
    }

    /// KOSync test double initializer (tests and previews written before connectors).
    convenience init(keychain: KeychainStore = KeychainStore(), defaults: UserDefaults = .standard,
                     clientFactory: @escaping (KOSyncCredentials) -> KOSyncClientProtocol) {
        self.init(keychain: keychain, defaults: defaults, makeConnector: { factory, creds in
            if factory.descriptor.id == KOSyncConnectorFactory.id,
               let k = KOSyncConnectorFactory.kosyncCredentials(from: creds) {
                return KOSyncConnector(client: clientFactory(k))
            }
            return factory.makeConnector(credentials: creds, store: InMemoryCredentialStore(creds), session: .shared)
        })
    }

    // MARK: Selection and form

    var selectedFactory: SyncConnectorFactory? { registry.factory(id: selectedConnectorID) }
    var activeFactory: SyncConnectorFactory? { activeConnectorID.flatMap(registry.factory(id:)) }

    /// True when the selected connector is the saved one and keeps a session (signed in: no form shown).
    var isSignedInToSelected: Bool {
        guard let f = selectedFactory, f.descriptor.id == activeConnectorID else { return false }
        return f.descriptor.usesSession
    }

    /// User name or email of the saved account.
    var accountLabel: String? {
        guard let f = activeFactory, let c = activeCredentials else { return nil }
        return f.accountLabel(for: c)
    }

    func value(for key: String) -> String { fields[key] ?? "" }
    func setValue(_ value: String, for key: String) { fields[key] = value }

    // KOSync form accessors (kept for the KOSync-specific warning and existing tests).
    var server: String {
        get { value(for: KOSyncConnectorFactory.Key.server) }
        set { setValue(newValue, for: KOSyncConnectorFactory.Key.server) }
    }
    var username: String {
        get { value(for: KOSyncConnectorFactory.Key.user) }
        set { setValue(newValue, for: KOSyncConnectorFactory.Key.user) }
    }
    var password: String {
        get { value(for: KOSyncConnectorFactory.Key.password) }
        set { setValue(newValue, for: KOSyncConnectorFactory.Key.password) }
    }

    var insecureWarning: String? {
        guard selectedConnectorID == KOSyncConnectorFactory.id else { return nil }
        return SyncSettingsValidator.insecureWarning(server: server)
    }

    private func loadForm() {
        status = nil
        guard let f = selectedFactory else { fields = [:]; return }
        if f.descriptor.id == activeConnectorID, let c = activeCredentials {
            fields = f.formValues(from: c)
        } else {
            var form: [String: String] = [:]
            for field in f.descriptor.credentialFields { form[field.key] = field.defaultValue ?? "" }
            fields = form
        }
    }

    // MARK: Storage

    var activeCredentials: SyncCredentials? {
        guard let f = activeFactory else { return nil }
        return credentials(for: f)
    }

    private func credentials(for f: SyncConnectorFactory) -> SyncCredentials? {
        var values: [String: String] = [:]
        for key in f.descriptor.storageKeys { if let v = keychain.get(account: key) { values[key] = v } }
        return values.isEmpty ? nil : SyncCredentials(values)
    }

    private static func loadActiveID(keychain: KeychainStore, defaults: UserDefaults,
                                     registry: SyncConnectorRegistry) -> String? {
        guard let id = defaults.string(forKey: connectorKey), let f = registry.factory(id: id) else { return nil }
        let hasAll = f.descriptor.credentialFields.isEmpty || f.descriptor.storageKeys.contains { keychain.get(account: $0) != nil }
        if id == KOSyncConnectorFactory.id {
            let k = KOSyncConnectorFactory.Key.self
            return SyncSettingsValidator.credentials(server: keychain.get(account: k.server) ?? "",
                                                     user: keychain.get(account: k.user) ?? "",
                                                     password: keychain.get(account: k.password) ?? "") != nil ? id : nil
        }
        return hasAll ? id : nil
    }

    /// Builds before connectors stored the KOSync login under the accounts server/username/password.
    private static func migrateLegacyKeychain(_ keychain: KeychainStore, defaults: UserDefaults) {
        guard let user = keychain.get(account: "username") else { return }
        let k = KOSyncConnectorFactory.Key.self
        let pairs = [("server", k.server), ("username", k.user), ("password", k.password)]
        for (old, new) in pairs {
            if let v = (old == "username" ? user : keychain.get(account: old)) { try? keychain.set(v, account: new) }
            keychain.remove(account: old)
        }
        defaults.set(KOSyncConnectorFactory.id, forKey: connectorKey)
    }

    private func nextStamp() -> Int {
        let previous = max(defaults.integer(forKey: Self.stampKey), defaults.integer(forKey: Self.clearedKey))
        return max(Int(Date().timeIntervalSince1970), previous + 1)
    }

    /// The saved settings to mirror on the watch, or nil if nothing valid is saved.
    func savedForWatch() -> PhoneConnectivity.WatchSettings? {
        guard let id = activeConnectorID, let creds = activeCredentials else { return nil }
        let stamp = defaults.integer(forKey: Self.stampKey)
        return .init(connectorID: id, credentials: creds, stamp: stamp > 0 ? stamp : 1)
    }

    /// Stamp of the last "turn off sync" while nothing valid is saved; nil if never turned off or if
    /// credentials were saved afterwards. Mirrored to the watch so it removes its copy.
    var clearedStamp: Int? {
        guard savedForWatch() == nil else { return nil }
        let v = defaults.integer(forKey: Self.clearedKey)
        return v > 0 ? v : nil
    }

    var hasCredentials: Bool {
        selectedConnectorID == KOSyncConnectorFactory.id
            && SyncSettingsValidator.credentials(server: server, user: username, password: password) != nil
    }

    // MARK: Actions

    /// Signs in with the selected connector (KOSync: validates only; Readest: password grant), stores the
    /// result in the Keychain and sends it to the watch. Replaces any previously saved service.
    func save() async {
        guard let f = selectedFactory else { return }
        isBusy = true
        status = nil
        defer { isBusy = false }
        let creds: SyncCredentials
        do {
            creds = try await f.signIn(fields: fields, session: session)
        } catch SyncConnectorError.missingFields {
            status = .missingFieldsStatus(for: f.descriptor.id)
            return
        } catch {
            status = .failure(SyncSettingsValidator.message(for: error))
            return
        }
        let previous = activeFactory.flatMap { old in activeCredentials.map { (old, $0) } }
        do {
            for key in registry.allStorageKeys { keychain.remove(account: key) }
            for (key, value) in creds.values { try keychain.set(value, account: key) }
        } catch {
            status = .failure(String(localized: "The login couldn’t be saved to this iPhone’s Keychain. Restart your iPhone and try again.",
                                     comment: "Sync status when the Keychain write fails"))
            return
        }
        // Strictly newer than any earlier save or turn-off so the watch applies it.
        defaults.set(nextStamp(), forKey: Self.stampKey)
        defaults.removeObject(forKey: Self.clearedKey)
        defaults.set(f.descriptor.id, forKey: Self.connectorKey)
        activeConnectorID = f.descriptor.id
        // The previous session (another service, or an older Readest sign-in) is no longer used.
        if let previous, previous.0.descriptor.usesSession {
            let session = self.session
            let oldFactory = previous.0, oldCreds = previous.1
            Task.detached { await oldFactory.signOut(credentials: oldCreds, session: session) }
        }
        if f.descriptor.usesSession {
            fields = f.formValues(from: creds)
            status = .success(String(localized: "Signed in. Sync is on. The session is sent to your Apple Watch now, or as soon as the watch app is installed.",
                                     comment: "Sync status after signing in to a sync service such as Readest"))
        } else {
            status = .success(String(localized: "Sync is on. The login is sent to your Apple Watch now, or as soon as the watch app is installed.",
                                     comment: "Sync status after saving"))
        }
        onSave?(creds)
    }

    /// Removes the saved login or session from the iPhone Keychain and tells the watch (settings channel,
    /// stamped) to remove its credentials and pending queue. Books and reading positions are untouched.
    /// A session (Readest) is also revoked on the server, best effort.
    func turnOff() {
        let wasSession = activeFactory?.descriptor.usesSession ?? false
        if let f = activeFactory, wasSession, let creds = activeCredentials {
            let session = self.session
            Task.detached { await f.signOut(credentials: creds, session: session) }
        }
        for key in registry.allStorageKeys { keychain.remove(account: key) }
        defaults.set(nextStamp(), forKey: Self.clearedKey)
        defaults.removeObject(forKey: Self.connectorKey)
        activeConnectorID = nil
        selectedConnectorID = ""
        fields = [:]
        if wasSession {
            status = .info(String(localized: "Signed out. The session was removed from this iPhone and your Apple Watch.",
                                  comment: "Sync status after signing out of a sync service such as Readest"))
        } else {
            status = .info(String(localized: "Sync is off. Your login was removed from this iPhone and your Apple Watch.",
                                  comment: "Sync status after turning sync off"))
        }
        onTurnOff?()
    }

    /// Checks the login in the form (KOSync). Not offered for session-based connectors: their sign-in
    /// already checks it, and refreshing a session here would invalidate the watch's copy.
    func testConnection() {
        guard let f = selectedFactory, f.descriptor.supportsConnectionTest else {
            status = .missingFields; return
        }
        isBusy = true
        status = nil
        let fields = self.fields
        let session = self.session
        let make = makeConnector
        Task {
            do {
                let creds = try await f.signIn(fields: fields, session: session)
                try await make(f, creds).authorize()
                status = .success(String(localized: "Connected. The server accepted your username and password.",
                                         comment: "Sync status after a successful connection test"))
            } catch SyncConnectorError.missingFields {
                status = .missingFieldsStatus(for: f.descriptor.id)
            } catch {
                status = .failure(SyncSettingsValidator.message(for: error))
            }
            isBusy = false
        }
    }
}

/// Preview/test double.
struct MockKOSyncClient: KOSyncClientProtocol {
    var authorizeError: Error?
    func authorize() async throws { if let authorizeError { throw authorizeError } }
    func createUser() async throws {}
    func pushProgress(_ progress: KOSyncProgress) async throws {}
    func fetchProgress(document: String) async throws -> KOSyncProgress? { nil }
}
