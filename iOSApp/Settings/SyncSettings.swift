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
            return "http:// is not encrypted. Acceptable on your home network only; the sync password hash and your reading progress travel in clear."
        }
        return "iOS blocks http:// to internet hosts (App Transport Security), so this will fail. Use https://, or a local address (IP, .local or a name without dots)."
    }

    /// Hosts that `NSAllowsLocalNetworking` lets through over http: IP literals, `.local`, dotless names.
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || !h.contains(".") || h.contains(":") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    static func message(for error: Error) -> String {
        if let u = error as? URLError, u.code == .appTransportSecurityRequiresSecureConnection {
            return "iOS blocked the plain http:// connection. Use https://, or a local-network address."
        }
        guard let e = error as? KOSyncError else { return error.localizedDescription }
        switch e {
        case .unauthorized: return "Wrong username or password."
        case .userExists: return "That username is already registered."
        case .offline: return "Server unreachable."
        case .notFound: return "Server did not recognise the request (check the URL)."
        case .server(let status): return "Server error (HTTP \(status))."
        case .invalidResponse: return "Unexpected server response."
        case .notImplemented: return "Not implemented."
        }
    }
}

/// Persists settings (Keychain) and pushes them to the watch.
@MainActor
final class SyncSettings: ObservableObject {
    @Published var server: String
    @Published var username: String
    @Published var password: String
    @Published var status: String?
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
            status = "Enter server, username and password."; return
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
            status = "Sync is on. The login is sent to the watch now, or as soon as the watch app is installed."
            onSave?(c)
        } catch {
            status = "Keychain error: \(error)"
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
        status = "Sync is off. Credentials were removed from this iPhone and the watch."
        onTurnOff?()
    }

    func testConnection() { run("Connection OK.") { try await $0.authorize() } }

    func createAccount() { run("Account created.") { try await $0.createUser() } }

    private func run(_ success: String, _ op: @escaping (KOSyncClientProtocol) async throws -> Void) {
        guard let c = SyncSettingsValidator.credentials(server: server, user: username, password: password) else {
            status = "Enter server, username and password."; return
        }
        isBusy = true
        status = nil
        let client = clientFactory(c)
        Task {
            do { try await op(client); status = success }
            catch { status = SyncSettingsValidator.message(for: error) }
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
