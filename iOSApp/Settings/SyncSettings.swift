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

    static func message(for error: Error) -> String {
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

    private let keychain: KeychainStore
    private let clientFactory: (KOSyncCredentials) -> KOSyncClientProtocol
    var onSave: ((KOSyncCredentials) -> Void)?

    init(keychain: KeychainStore = KeychainStore(),
         clientFactory: @escaping (KOSyncCredentials) -> KOSyncClientProtocol = { KOSyncClient(credentials: $0) }) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        server = keychain.get(account: "server") ?? SyncSettingsValidator.defaultServer
        username = keychain.get(account: "username") ?? ""
        password = keychain.get(account: "password") ?? ""
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
            status = "Saved and sent to watch."
            onSave?(c)
        } catch {
            status = "Keychain error: \(error)"
        }
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
