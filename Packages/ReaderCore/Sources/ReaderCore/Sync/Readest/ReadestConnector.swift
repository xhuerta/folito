import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Maps between Folito's `ReadingPosition` and Readest `book_configs` rows. Pure, unit-tested.
///
/// Readest stores two position fields: `location` (an EPUB CFI, written only by the Readest apps) and
/// `xpointer` (a KOReader XPointer, written by the koplugin and by the Readest apps, which convert their
/// CFI with `getXPointerFromCFI`). Folito positions already are KOReader XPointers, so only `xpointer`
/// and the `[page, total]` `progress` pair are used; `location` is never written (a push that omits it
/// leaves the stored CFI untouched, exactly like the koplugin's pushes).
public enum ReadestProgressMapper {
    /// Denominator for `progress` when the reader has no page count.
    public static let fallbackPageCount = 1000
    /// A sibling copy's fraction must beat the exact copy by this much (Readest `SIBLING_FORWARD_EPSILON`).
    public static let siblingEpsilon = 0.002

    public static func config(for position: ReadingPosition, book: BookIdentity, now: Date) -> ReadestBookConfig {
        let pct = position.percentage.isFinite ? min(max(position.percentage, 0), 1) : 0
        let progress: [Int]
        if let page = position.page, let count = position.pageCount, count > 0, (1...count).contains(page) {
            progress = [page, count]
        } else {
            progress = [max(1, Int((pct * Double(fallbackPageCount)).rounded())), fallbackPageCount]
        }
        return ReadestBookConfig(bookHash: book.partialMD5, metaHash: book.metaHash, xpointer: position.xpointer,
                                 progress: progress, updatedAt: position.timestamp ?? now)
    }

    /// The position to offer for `book` among the rows the server returned (same `book_hash` or same
    /// `meta_hash`), following Readest's `applyRemoteProgress`: the exact copy's XPointer is trusted; a
    /// sibling copy (different file, same metadata) contributes only its reading fraction, and only when it
    /// is further than the exact copy, because its XPointer may point elsewhere in this file.
    public static func position(from rows: [ReadestBookConfig], book: BookIdentity) -> ReadingPosition? {
        let live = rows.filter { $0.deletedAt == nil }
        let exact = live.filter { $0.bookHash == book.partialMD5 }.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        let siblings = live.filter {
            $0.bookHash != book.partialMD5 && book.metaHash != nil && $0.metaHash == book.metaHash
        }
        let bestSibling = siblings.max { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
        let exactFraction = exact?.fraction ?? 0
        if let s = bestSibling, let f = s.fraction, f > exactFraction + siblingEpsilon {
            return ReadingPosition(xpointer: "", percentage: f, page: s.progress?[0], pageCount: s.progress?[1],
                                   timestamp: s.updatedAt, deviceID: "", deviceName: "")
        }
        guard let e = exact, e.xpointer != nil || e.fraction != nil else { return nil }
        return ReadingPosition(xpointer: e.xpointer ?? "", percentage: e.fraction ?? 0,
                               page: e.progress?[0], pageCount: e.progress?[1],
                               timestamp: e.updatedAt, deviceID: "", deviceName: "")
    }
}

/// Readest Cloud behind `SyncConnector`.
public struct ReadestConnector: SyncConnector {
    public var descriptor: SyncConnectorDescriptor { ReadestConnectorFactory.descriptorValue }
    let auth: ReadestAuth
    let client: ReadestSyncClient
    let clock: ReadestClock

    public init(auth: ReadestAuth, client: ReadestSyncClient, clock: ReadestClock = SystemReadestClock()) {
        self.auth = auth
        self.client = client
        self.clock = clock
    }

    public func authorize() async throws {
        _ = try await auth.validAccessToken()
        try await client.ping()
    }

    public func fetchProgress(for book: BookIdentity) async throws -> ReadingPosition? {
        let rows = try await client.fetchConfigs(bookHash: book.partialMD5, metaHash: book.metaHash)
        return ReadestProgressMapper.position(from: rows, book: book)
    }

    /// `updatedAt` is when the position was reached, not when it is sent: the server's last-writer-wins
    /// then never lets a position that waited offline overwrite a newer one from the Kobo or Readest.
    public func pushProgress(_ position: ReadingPosition, for book: BookIdentity) async throws {
        try await client.pushConfig(ReadestProgressMapper.config(for: position, book: book, now: clock.now()))
    }
}

public struct ReadestConnectorFactory: SyncConnectorFactory {
    public static let id = "readest"

    public enum Key {
        public static let email = "readest_email"
        public static let password = "readest_password"
        /// JSON `ReadestSession` (access + refresh token). The password is never stored.
        public static let session = "readest_session"
        /// "1" after the server rejected the refresh token.
        public static let authRequired = "readest_auth_required"
    }

    static let descriptorValue = SyncConnectorDescriptor(
        id: id,
        displayName: "Readest",
        summary: "Readest Cloud, the sync service of the Readest apps and the Readest plugin for KOReader.",
        capabilities: .progress,
        authKind: .emailPassword,
        credentialFields: [
            CredentialField(key: Key.email, kind: .email, label: "Email"),
            CredentialField(key: Key.password, kind: .password, label: "Password"),
        ],
        storageKeys: [Key.email, Key.session, Key.authRequired],
        staleCheckRequiresDeviceID: false,
        hosts: ["vbsyxfusjjqdxkjqlysc.supabase.co", "web.readest.com"])

    public var descriptor: SyncConnectorDescriptor { Self.descriptorValue }
    let config: ReadestConfiguration

    public init(config: ReadestConfiguration = .readestCloud) { self.config = config }

    public func signIn(fields: [String: String], session: URLSession) async throws -> SyncCredentials {
        let email = (fields[Key.email] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = fields[Key.password] ?? ""
        guard email.contains("@"), !password.isEmpty else { throw SyncConnectorError.missingFields }
        let auth = ReadestAuth(config: config, session: session, store: InMemoryCredentialStore())
        let s = try await auth.signIn(email: email, password: password)
        return SyncCredentials([Key.email: s.email ?? email, Key.session: s.jsonString()])
    }

    public func makeConnector(credentials: SyncCredentials, store: SyncCredentialStore,
                              session: URLSession) -> SyncConnector {
        if store.load() == nil { store.save(credentials) }
        let auth = ReadestAuth(config: config, session: session, store: store)
        return ReadestConnector(auth: auth, client: ReadestSyncClient(config: config, session: session, auth: auth))
    }

    public func signOut(credentials: SyncCredentials, session: URLSession) async {
        guard let s = credentials[Key.session].flatMap(ReadestSession.init(jsonString:)) else { return }
        let auth = ReadestAuth(config: config, session: session, store: InMemoryCredentialStore(credentials))
        await auth.revoke(accessToken: s.accessToken)
    }

    public func formValues(from credentials: SyncCredentials) -> [String: String] {
        [Key.email: credentials[Key.email] ?? "", Key.password: ""]
    }

    public func accountLabel(for credentials: SyncCredentials) -> String? { credentials[Key.email] }
}
