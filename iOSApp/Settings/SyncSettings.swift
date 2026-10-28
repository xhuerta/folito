import Foundation
import ReaderCore

/// Pure validation of the user-entered KOSync form.
enum SyncSettingsValidator {
    static let defaultServer = "https://sync.koreader.rocks"

    static func credentials(server: String, user: String, password: String) -> KOSyncCredentials? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = defaultServer }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil, !u.isEmpty, !password.isEmpty else { return nil }
        return KOSyncCredentials(serverURL: url, username: u, password: password)
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
}

/// Persists settings (Keychain) and pushes them to the watch.
@MainActor
final class SyncSettings: ObservableObject {
    @Published var server: String
    @Published var username: String
    @Published var password: String
    @Published var status: SyncStatus?
    @Published var isBusy = false
    /// Sync is ON only when valid credentials are saved in the Keychain. The prefilled default server
    /// or unsaved text in the form never counts.
    @Published private(set) var isSyncOn = false

    private let keychain: KeychainStore
    private let clientFactory: (KOSyncCredentials) -> KOSyncClientProtocol
    var onSave: ((KOSyncCredentials) -> Void)?
    var onTurnOff: (() -> Void)?
    private let defaults: UserDefaults
    private static let stampKey = "settings.savedAt"
    private static let clearedKey = "settings.clearedAt"

    var insecureWarning: String? { SyncSettingsValidator.insecureWarning(server: server) }

    /// The saved (Keychain) settings to mirror on the watch, or nil if nothing valid is saved.
    func savedForWatch() -> PhoneConnectivity.WatchSettings? {
        guard let c = SyncSettingsValidator.credentials(server: keychain.get(account: "server") ?? "",
                                                        user: keychain.get(account: "username") ?? "",
                                                        password: keychain.get(account: "password") ?? "") else { return nil }
        let stamp = defaults.integer(forKey: Self.stampKey)
        return .init(server: c.serverURL.absoluteString, user: c.username, password: c.password,
                     stamp: stamp > 0 ? stamp : 1)
    }

    /// Stamp of the last "turn off sync" while nothing valid is saved; nil if never turned off or if
    /// credentials were saved afterwards. Mirrored to the watch so it removes its copy.
    var clearedStamp: Int? {
        guard savedForWatch() == nil else { return nil }
        let v = defaults.integer(forKey: Self.clearedKey)
        return v > 0 ? v : nil
    }

    init(keychain: KeychainStore = KeychainStore(), defaults: UserDefaults = .standard,
         clientFactory: @escaping (KOSyncCredentials) -> KOSyncClientProtocol = { KOSyncClient(credentials: $0) }) {
        self.keychain = keychain
        self.defaults = defaults
        self.clientFactory = clientFactory
        server = keychain.get(account: "server") ?? SyncSettingsValidator.defaultServer
        username = keychain.get(account: "username") ?? ""
        password = keychain.get(account: "password") ?? ""
        isSyncOn = savedForWatch() != nil
    }

    var hasCredentials: Bool { SyncSettingsValidator.credentials(server: server, user: username, password: password) != nil }

    func save() {
        guard let c = SyncSettingsValidator.credentials(server: server, user: username, password: password) else {
            status = .missingFields; return
        }
        do {
            try keychain.set(c.serverURL.absoluteString, account: "server")
            try keychain.set(c.username, account: "username")
            try keychain.set(c.password, account: "password")
            // Strictly newer than any earlier save or turn-off so the watch applies it.
            let previous = max(defaults.integer(forKey: Self.stampKey), defaults.integer(forKey: Self.clearedKey))
            defaults.set(max(Int(Date().timeIntervalSince1970), previous + 1), forKey: Self.stampKey)
            defaults.removeObject(forKey: Self.clearedKey)
            isSyncOn = true
            status = .success(String(localized: "Sync is on. The login is sent to your Apple Watch now, or as soon as the watch app is installed.",
                                     comment: "Sync status after saving"))
            onSave?(c)
        } catch {
            status = .failure(String(localized: "The login couldn’t be saved to this iPhone’s Keychain. Restart your iPhone and try again.",
                                     comment: "Sync status when the Keychain write fails"))
        }
    }

    /// Removes the saved login from the iPhone Keychain and tells the watch (settings channel, stamped)
    /// to remove its credentials and pending queue. Books and reading positions are untouched.
    func turnOff() {
        for account in ["server", "username", "password"] { keychain.remove(account: account) }
        let previous = max(defaults.integer(forKey: Self.stampKey), defaults.integer(forKey: Self.clearedKey))
        defaults.set(max(Int(Date().timeIntervalSince1970), previous + 1), forKey: Self.clearedKey)
        server = SyncSettingsValidator.defaultServer
        username = ""
        password = ""
        isSyncOn = false
        status = .info(String(localized: "Sync is off. Your login was removed from this iPhone and your Apple Watch.",
                              comment: "Sync status after turning sync off"))
        onTurnOff?()
    }

    // No "create account" action: accounts are created on the sync server itself. KOSync has no
    // account-deletion endpoint, and App Review guideline 5.1.1(v) requires in-app deletion for any
    // account an app creates.
    func testConnection() {
        run(String(localized: "Connected. The server accepted your username and password.",
                   comment: "Sync status after a successful connection test")) { try await $0.authorize() }
    }

    private func run(_ success: String, _ op: @escaping (KOSyncClientProtocol) async throws -> Void) {
        guard let c = SyncSettingsValidator.credentials(server: server, user: username, password: password) else {
            status = .missingFields; return
        }
        isBusy = true
        status = nil
        let client = clientFactory(c)
        Task {
            do { try await op(client); status = .success(success) }
            catch { status = .failure(SyncSettingsValidator.message(for: error)) }
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
