import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Connector-neutral progress sync model. See docs/SYNC_CONNECTORS.md ("How to add a connector").

/// Every identifier Folito knows for a book. Each connector picks the ones its service keys on.
public struct BookIdentity: Codable, Sendable, Hashable {
    /// KOReader `util.partialMD5` of the EPUB file (KOSync `document`, Readest `book_hash`).
    public var partialMD5: String
    /// Readest `meta_hash` (md5 of "title|authors|identifier"), when the book's metadata is known.
    public var metaHash: String?
    public var fileName: String?
    public var title: String?
    public var authors: [String]

    public init(partialMD5: String, metaHash: String? = nil, fileName: String? = nil,
                title: String? = nil, authors: [String] = []) {
        self.partialMD5 = partialMD5
        self.metaHash = metaHash
        self.fileName = fileName
        self.title = title
        self.authors = authors
    }

    /// Key used by the sync queue and in `SyncFlushResult`.
    public var key: String { partialMD5 }

    enum CodingKeys: String, CodingKey { case partialMD5, metaHash, fileName, title, authors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partialMD5 = try c.decode(String.self, forKey: .partialMD5)
        metaHash = try c.decodeIfPresent(String.self, forKey: .metaHash)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
    }
}

/// A reading position in Folito's terms, independent of any service.
public struct ReadingPosition: Codable, Sendable, Equatable {
    /// KOReader/crengine XPointer (`/body/DocFragment[N]/body/...`); empty when only a percentage is known.
    public var xpointer: String
    /// 0...1.
    public var percentage: Double
    public var chapter: String?
    /// 1-based position in the reader's own pagination (Folito: block index + 1), when known.
    public var page: Int?
    public var pageCount: Int?
    /// When the position was reached (local) or saved (remote, service clock).
    public var timestamp: Date?
    public var deviceID: String
    public var deviceName: String

    public init(xpointer: String, percentage: Double, chapter: String? = nil, page: Int? = nil,
                pageCount: Int? = nil, timestamp: Date? = nil, deviceID: String = "", deviceName: String = "") {
        self.xpointer = xpointer
        self.percentage = percentage
        self.chapter = chapter
        self.page = page
        self.pageCount = pageCount
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    /// Same place (ignores timestamp and device): used to skip re-sending an unchanged position.
    public func isSamePlace(as other: ReadingPosition) -> Bool {
        xpointer == other.xpointer && percentage == other.percentage
    }
}

public struct SyncCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let progressPull = SyncCapabilities(rawValue: 1 << 0)
    public static let progressPush = SyncCapabilities(rawValue: 1 << 1)
    /// Reserved: highlights / notes / bookmarks. No connector implements it yet.
    public static let annotations = SyncCapabilities(rawValue: 1 << 2)
    public static let progress: SyncCapabilities = [.progressPull, .progressPush]
}

public enum SyncAuthKind: String, Sendable, Codable {
    case none, usernamePassword, emailPassword, token, oauth
}

/// One input of a connector's sign-in form. The settings UI is generated from these.
public struct CredentialField: Sendable, Equatable {
    public enum Kind: String, Sendable { case url, username, email, password, token }

    /// Key in the form dictionary passed to `SyncConnectorFactory.signIn(fields:)`.
    public var key: String
    public var kind: Kind
    /// English source text; the apps look it up in their String Catalog.
    public var label: String
    public var placeholder: String?
    /// Prefilled value (e.g. the default server URL).
    public var defaultValue: String?
    public var isOptional: Bool
    /// Footer text under the field (English source, localized by the app).
    public var footer: String?

    public init(key: String, kind: Kind, label: String, placeholder: String? = nil, defaultValue: String? = nil,
                isOptional: Bool = false, footer: String? = nil) {
        self.key = key
        self.kind = kind
        self.label = label
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.isOptional = isOptional
        self.footer = footer
    }

    public var isSecret: Bool { kind == .password || kind == .token }
}

/// What a connector keeps after sign-in (and what crosses WatchConnectivity): a flat string map whose
/// keys are the connector's `storageKeys`. Values are secrets; never log them.
public struct SyncCredentials: Codable, Sendable, Equatable {
    public var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public subscript(key: String) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }
    public var isEmpty: Bool { values.isEmpty }

    public func jsonString() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public init?(jsonString: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(jsonString.utf8))) as? [String: Any] else {
            return nil
        }
        values = obj.compactMapValues { $0 as? String }
    }
}

/// Static description of a connector: identity, capabilities, auth and storage.
public struct SyncConnectorDescriptor: Sendable, Equatable {
    /// Stable id: persisted, sent to the watch, used as queue key. Never change it once shipped.
    public var id: String
    /// English source name; the apps localize it (String Catalog).
    public var displayName: String
    /// One-line English description shown in the picker footer.
    public var summary: String
    public var capabilities: SyncCapabilities
    public var authKind: SyncAuthKind
    public var credentialFields: [CredentialField]
    /// Keys of `SyncCredentials` this connector stores (Keychain accounts on both devices).
    public var storageKeys: [String]
    /// Whether the stale check may only trust remote positions that carry another device's id
    /// (KOSync). Readest stores no device id but its `updated_at` is the writer's own clock, so a newer
    /// one always comes from another write.
    public var staleCheckRequiresDeviceID: Bool
    /// Host names the connector talks to (privacy docs / App Privacy).
    public var hosts: [String]

    public init(id: String, displayName: String, summary: String, capabilities: SyncCapabilities,
                authKind: SyncAuthKind, credentialFields: [CredentialField], storageKeys: [String],
                staleCheckRequiresDeviceID: Bool, hosts: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.capabilities = capabilities
        self.authKind = authKind
        self.credentialFields = credentialFields
        self.storageKeys = storageKeys
        self.staleCheckRequiresDeviceID = staleCheckRequiresDeviceID
        self.hosts = hosts
    }
}

/// A live, signed-in connection to one sync service.
public protocol SyncConnector: Sendable {
    var descriptor: SyncConnectorDescriptor { get }
    /// Checks that the stored credentials are accepted.
    func authorize() async throws
    /// The service's position for `book`, or nil when it has none.
    func fetchProgress(for book: BookIdentity) async throws -> ReadingPosition?
    /// Saves `position`. Must not overwrite a newer server position when the service can tell.
    func pushProgress(_ position: ReadingPosition, for book: BookIdentity) async throws
}

/// Where a connector persists credentials that change after sign-in (rotating tokens).
public protocol SyncCredentialStore: Sendable {
    func load() -> SyncCredentials?
    /// nil removes everything.
    func save(_ credentials: SyncCredentials?)
}

public final class InMemoryCredentialStore: SyncCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: SyncCredentials?
    public init(_ value: SyncCredentials? = nil) { self.value = value }
    public func load() -> SyncCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ credentials: SyncCredentials?) { lock.lock(); value = credentials; lock.unlock() }
}

/// Builds connectors of one kind. Registered in `SyncConnectorRegistry`.
public protocol SyncConnectorFactory: Sendable {
    var descriptor: SyncConnectorDescriptor { get }
    /// Turns the sign-in form (keys = `credentialFields[].key`) into the credentials to store. May contact
    /// the service (e.g. a password grant). Throws `SyncConnectorError.missingFields` for incomplete input.
    func signIn(fields: [String: String], session: URLSession) async throws -> SyncCredentials
    /// A connector for stored credentials. `store` receives rotated credentials.
    func makeConnector(credentials: SyncCredentials, store: SyncCredentialStore, session: URLSession) -> SyncConnector
    /// Best-effort server-side sign-out. Local removal is the caller's job.
    func signOut(credentials: SyncCredentials, session: URLSession) async
    /// Prefills the sign-in form from stored credentials (never returns secrets that are not stored).
    func formValues(from credentials: SyncCredentials) -> [String: String]
    /// Account label shown when signed in (user name or email), if any.
    func accountLabel(for credentials: SyncCredentials) -> String?
}

public extension SyncConnectorFactory {
    func signOut(credentials: SyncCredentials, session: URLSession) async {}
}

/// Neutral errors for connectors without their own error type, and form validation.
public enum SyncConnectorError: Error, Equatable {
    case missingFields
    case notConfigured
    case unauthorized
    case offline
    case rateLimited
    case server(status: Int)
    case invalidResponse
}

/// How the queue treats a failure.
public enum SyncErrorDisposition: Sendable, Equatable {
    /// Retry with backoff (offline, 5xx, 429).
    case transient
    /// Keep the entry, stop the background loop until credentials change.
    case unauthorized
    /// Drop the entry.
    case permanent
}

public protocol SyncErrorClassifying: Error {
    var syncDisposition: SyncErrorDisposition { get }
}

extension SyncConnectorError: SyncErrorClassifying {
    public var syncDisposition: SyncErrorDisposition {
        switch self {
        case .offline, .rateLimited: return .transient
        case .server(let s): return (s >= 500 || s == 429) ? .transient : .permanent
        case .unauthorized, .notConfigured: return .unauthorized
        case .missingFields, .invalidResponse: return .permanent
        }
    }
}

public enum SyncErrors {
    public static func disposition(of error: Error) -> SyncErrorDisposition {
        if let e = error as? SyncErrorClassifying { return e.syncDisposition }
        if error is URLError { return .transient }
        return .permanent
    }

    public static func isOffline(_ error: Error) -> Bool {
        switch error {
        case KOSyncError.offline, ReadestError.offline, SyncConnectorError.offline: return true
        case let u as URLError: return ReadestHTTP.offlineCodes.contains(u.code)
        default: return false
        }
    }

    public static func isUnauthorized(_ error: Error) -> Bool { disposition(of: error) == .unauthorized }
}

/// All connectors the apps offer, in picker order. "None" is not a connector: it is the absence of one.
public struct SyncConnectorRegistry: Sendable {
    public let factories: [SyncConnectorFactory]

    public init(_ factories: [SyncConnectorFactory]) { self.factories = factories }

    public static let standard = SyncConnectorRegistry([KOSyncConnectorFactory(), ReadestConnectorFactory()])

    public var descriptors: [SyncConnectorDescriptor] { factories.map(\.descriptor) }

    public func factory(id: String) -> SyncConnectorFactory? { factories.first { $0.descriptor.id == id } }

    /// Every storage key of every connector (to wipe all credentials on sign-out / switch).
    public var allStorageKeys: [String] {
        var seen = Set<String>()
        return factories.flatMap(\.descriptor.storageKeys).filter { seen.insert($0).inserted }
    }
}

/// Settings-channel payload (phone -> watch): which connector is active and its credentials.
/// Generic for every connector; see docs/WATCH_CONNECTIVITY.md.
public enum SyncSettingsWire {
    public static let connectorKey = "sync_connector"
    public static let credentialsKey = "sync_credentials"
    public static let clearedKey = "sync_cleared"
    /// Version of the settings payload. 2 = generic connector keys (this format); 1 = KOSync-only keys.
    public static let versionKey = "settingsVersion"
    public static let version = 2

    public static func encode(connectorID: String, credentials: SyncCredentials) -> [String: Any] {
        [connectorKey: connectorID, credentialsKey: credentials.jsonString(), versionKey: version]
    }

    /// (connector id, credentials) when the dictionary carries the generic keys.
    public static func decode(_ info: [String: Any]) -> (String, SyncCredentials)? {
        guard let id = info[connectorKey] as? String, !id.isEmpty,
              let json = info[credentialsKey] as? String, let creds = SyncCredentials(jsonString: json) else { return nil }
        return (id, creds)
    }
}
