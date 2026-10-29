import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension KOSyncError: SyncErrorClassifying {
    public var syncDisposition: SyncErrorDisposition {
        switch self {
        case .offline: return .transient
        case .server(let s): return (s >= 500 || s == 429) ? .transient : .permanent
        case .unauthorized: return .unauthorized
        default: return .permanent
        }
    }
}

public extension KOSyncProgress {
    /// Neutral form of a KOSync record.
    var readingPosition: ReadingPosition {
        ReadingPosition(xpointer: progress, percentage: percentage,
                        timestamp: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        deviceID: device_id, deviceName: device)
    }

    var bookIdentity: BookIdentity { BookIdentity(partialMD5: document) }

    init(book: BookIdentity, position: ReadingPosition) {
        self.init(document: book.partialMD5, progress: position.xpointer, percentage: position.percentage,
                  device: position.deviceName, device_id: position.deviceID,
                  timestamp: position.timestamp.map { Int($0.timeIntervalSince1970) })
    }
}

/// KOReader Sync (kosync) behind `SyncConnector`. Behaviour is exactly `KOSyncClient`'s.
public struct KOSyncConnector: SyncConnector {
    public let client: KOSyncClientProtocol
    public var descriptor: SyncConnectorDescriptor { KOSyncConnectorFactory.descriptorValue }

    public init(client: KOSyncClientProtocol) { self.client = client }

    public func authorize() async throws { try await client.authorize() }

    public func fetchProgress(for book: BookIdentity) async throws -> ReadingPosition? {
        try await client.fetchProgress(document: book.partialMD5)?.readingPosition
    }

    public func pushProgress(_ position: ReadingPosition, for book: BookIdentity) async throws {
        try await client.pushProgress(KOSyncProgress(book: book, position: position))
    }
}

public struct KOSyncConnectorFactory: SyncConnectorFactory {
    public static let id = "kosync"
    public static let defaultServer = "https://sync.koreader.rocks"

    /// Storage keys = the Keychain accounts the watch has used since the first release (kept for upgrades).
    public enum Key {
        public static let server = "kosync_server"
        public static let user = "kosync_user"
        public static let password = "kosync_password"
    }

    static let descriptorValue = SyncConnectorDescriptor(
        id: id,
        displayName: "KOReader Sync",
        summary: "Any KOReader Sync-compatible server, for example KOReader’s, Readest’s or one you host yourself.",
        capabilities: .progress,
        authKind: .usernamePassword,
        credentialFields: [
            CredentialField(key: Key.server, kind: .url, label: "Server URL", defaultValue: defaultServer,
                            isOptional: true),
            CredentialField(key: Key.user, kind: .username, label: "Username"),
            CredentialField(key: Key.password, kind: .password, label: "Password"),
        ],
        storageKeys: [Key.server, Key.user, Key.password],
        staleCheckRequiresDeviceID: true,
        hosts: ["sync.koreader.rocks (or the server you enter)"])

    public var descriptor: SyncConnectorDescriptor { Self.descriptorValue }

    public init() {}

    /// Normalizes the form: empty server -> default, scheme added, trailing slashes removed. Nil if invalid.
    public static func credentials(server: String, user: String, password: String) -> KOSyncCredentials? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = defaultServer }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil, !u.isEmpty, !password.isEmpty else { return nil }
        return KOSyncCredentials(serverURL: url, username: u, password: password)
    }

    public static func kosyncCredentials(from c: SyncCredentials) -> KOSyncCredentials? {
        credentials(server: c[Key.server] ?? "", user: c[Key.user] ?? "", password: c[Key.password] ?? "")
    }

    public static func storedCredentials(_ c: KOSyncCredentials) -> SyncCredentials {
        SyncCredentials([Key.server: c.serverURL.absoluteString, Key.user: c.username, Key.password: c.password])
    }

    /// No network: KOSync has no session, the login is checked by `authorize()` ("Test Connection").
    public func signIn(fields: [String: String], session: URLSession) async throws -> SyncCredentials {
        guard let c = Self.credentials(server: fields[Key.server] ?? "", user: fields[Key.user] ?? "",
                                       password: fields[Key.password] ?? "") else {
            throw SyncConnectorError.missingFields
        }
        return Self.storedCredentials(c)
    }

    public func makeConnector(credentials: SyncCredentials, store: SyncCredentialStore,
                              session: URLSession) -> SyncConnector {
        guard let c = Self.kosyncCredentials(from: credentials) else { return UnconfiguredConnector() }
        return KOSyncConnector(client: KOSyncClient(credentials: c, session: session))
    }

    public func formValues(from credentials: SyncCredentials) -> [String: String] {
        [Key.server: credentials[Key.server] ?? Self.defaultServer,
         Key.user: credentials[Key.user] ?? "",
         Key.password: credentials[Key.password] ?? ""]
    }

    public func accountLabel(for credentials: SyncCredentials) -> String? { credentials[Key.user] }
}

/// Stand-in while no connector is configured: every call fails with `.notConfigured` (kept, not dropped).
public struct UnconfiguredConnector: SyncConnector {
    public static let descriptorValue = SyncConnectorDescriptor(
        id: "", displayName: "None", summary: "", capabilities: [], authKind: .none, credentialFields: [],
        storageKeys: [], staleCheckRequiresDeviceID: true)
    public var descriptor: SyncConnectorDescriptor { Self.descriptorValue }
    public init() {}
    public func authorize() async throws { throw SyncConnectorError.notConfigured }
    public func fetchProgress(for book: BookIdentity) async throws -> ReadingPosition? {
        throw SyncConnectorError.notConfigured
    }
    public func pushProgress(_ position: ReadingPosition, for book: BookIdentity) async throws {
        throw SyncConnectorError.notConfigured
    }
}
