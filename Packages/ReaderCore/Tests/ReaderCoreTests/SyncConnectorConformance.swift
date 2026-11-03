import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReaderCore

/// Reusable conformance checks for any `SyncConnectorFactory` / `SyncConnector`.
/// A new connector adds one test case that builds a `ConnectorHarness` against its fake server and calls
/// `SyncConnectorConformance.verify(_:)` (see docs/SYNC_CONNECTORS.md). Plain functions rather than an
/// XCTestCase base class, because swift-corelibs-xctest does not run inherited test methods on Linux.
struct ConnectorHarness {
    let factory: SyncConnectorFactory
    /// A complete, valid sign-in form for the fake server.
    let form: [String: String]
    let session: URLSession
}

enum SyncConnectorConformance {
    static func verify(_ h: ConnectorHarness, file: StaticString = #filePath, line: UInt = #line) async throws {
        checkDescriptor(h.factory.descriptor, file: file, line: line)
        try await checkSignIn(h, file: file, line: line)
        try await checkRoundTrip(h, file: file, line: line)
        try await checkQueueNeverOverwritesNewerRemote(h, file: file, line: line)
        try await checkQueueDropsOtherConnectorsEntries(h, file: file, line: line)
    }

    static func connector(_ h: ConnectorHarness) async throws -> (SyncConnector, SyncCredentials) {
        let creds = try await h.factory.signIn(fields: h.form, session: h.session)
        return (h.factory.makeConnector(credentials: creds, store: InMemoryCredentialStore(creds), session: h.session), creds)
    }

    static func randomBook() -> BookIdentity {
        let hex = { (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined() }
        return BookIdentity(partialMD5: hex(), metaHash: hex(), title: "Conformance", authors: ["Test"])
    }

    static func checkDescriptor(_ d: SyncConnectorDescriptor, file: StaticString, line: UInt) {
        XCTAssertFalse(d.id.isEmpty, "id must be stable and non-empty", file: file, line: line)
        XCTAssertEqual(d.id, d.id.lowercased(), "ids are lowercase", file: file, line: line)
        XCTAssertFalse(d.displayName.isEmpty, file: file, line: line)
        XCTAssertTrue(d.capabilities.contains(.progress), "progress pull + push are required", file: file, line: line)
        let keys = d.credentialFields.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "field keys are unique", file: file, line: line)
        XCTAssertFalse(d.storageKeys.isEmpty, "credentials must be storable", file: file, line: line)
        XCTAssertTrue(d.credentialFields.contains { !$0.isOptional } || d.authKind == .none, file: file, line: line)
        let others = SyncConnectorRegistry.standard.descriptors.filter { $0.id != d.id }
        for o in others {
            XCTAssertTrue(Set(o.storageKeys).isDisjoint(with: d.storageKeys),
                          "storage keys must not collide with \(o.id)", file: file, line: line)
        }
    }

    static func checkSignIn(_ h: ConnectorHarness, file: StaticString, line: UInt) async throws {
        do {
            _ = try await h.factory.signIn(fields: [:], session: h.session)
            XCTFail("an empty form must be rejected", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SyncConnectorError, .missingFields, file: file, line: line)
        }
        let (c, creds) = try await connector(h)
        XCTAssertTrue(Set(creds.values.keys).isSubset(of: Set(h.factory.descriptor.storageKeys)),
                      "signIn returns only declared storage keys", file: file, line: line)
        XCTAssertNotNil(h.factory.accountLabel(for: creds), file: file, line: line)
        for field in h.factory.descriptor.credentialFields where field.isSecret {
            XCTAssertNotNil(h.factory.formValues(from: creds)[field.key], file: file, line: line)
        }
        try await c.authorize()
    }

    static func checkRoundTrip(_ h: ConnectorHarness, file: StaticString, line: UInt) async throws {
        let (c, _) = try await connector(h)
        let book = randomBook()
        let none = try await c.fetchProgress(for: book)
        XCTAssertNil(none, "an unknown book has no remote position", file: file, line: line)
        let xp = "/body/DocFragment[3]/body/p[7]/text().12"
        let pos = ReadingPosition(xpointer: xp, percentage: 0.25, page: 25, pageCount: 100, timestamp: Date(),
                                  deviceID: "conformance-a", deviceName: "Folito")
        try await c.pushProgress(pos, for: book)
        let back = try await c.fetchProgress(for: book)
        XCTAssertEqual(back?.xpointer, xp, file: file, line: line)
        XCTAssertEqual(back?.percentage ?? -1, 0.25, accuracy: 0.001, file: file, line: line)
        XCTAssertNotNil(back?.timestamp, "the stale check needs remote timestamps", file: file, line: line)

        let later = ReadingPosition(xpointer: "/body/DocFragment[4]/body/p[1]", percentage: 0.5,
                                    timestamp: Date().addingTimeInterval(2), deviceID: "conformance-a")
        try await c.pushProgress(later, for: book)
        let latest = try await c.fetchProgress(for: book)
        XCTAssertEqual(latest?.xpointer, later.xpointer, "a newer push replaces the position", file: file, line: line)
    }

    static func checkQueueNeverOverwritesNewerRemote(_ h: ConnectorHarness, file: StaticString, line: UInt) async throws {
        let (mine, _) = try await connector(h)
        let (other, _) = try await connector(h)
        let book = randomBook()
        // Another device saves a position now; ours was reached ten minutes ago and waited offline.
        try await other.pushProgress(ReadingPosition(xpointer: "/body/DocFragment[9]/body/p[1]", percentage: 0.9,
                                                     timestamp: Date(), deviceID: "other-device", deviceName: "Kobo"),
                                     for: book)
        let queue = SyncQueue(connector: mine)
        await queue.enqueue(ReadingPosition(xpointer: "/body/DocFragment[2]/body/p[1]", percentage: 0.1,
                                            timestamp: Date().addingTimeInterval(-600), deviceID: "my-watch"),
                            for: book)
        let r = await queue.flush(force: true)
        XCTAssertEqual(r.superseded, [book.key], "a stale entry must not overwrite a newer remote", file: file, line: line)
        let remote = try await mine.fetchProgress(for: book)
        XCTAssertEqual(remote?.percentage ?? 0, 0.9, accuracy: 0.001, file: file, line: line)
    }

    static func checkQueueDropsOtherConnectorsEntries(_ h: ConnectorHarness, file: StaticString, line: UInt) async throws {
        let (c, _) = try await connector(h)
        let book = randomBook()
        let queue = SyncQueue(connector: c)
        await queue.enqueue(SyncEntry(connectorID: "some-other-service", book: book,
                                      position: ReadingPosition(xpointer: "/body/p", percentage: 0.3, timestamp: Date())))
        let r = await queue.flush(force: true)
        XCTAssertEqual(r.dropped, [book.key], "entries recorded for another service are never sent", file: file, line: line)
        let remote = try await c.fetchProgress(for: book)
        XCTAssertNil(remote, file: file, line: line)
    }
}

// MARK: - Fake servers (wire behaviour copied from the real servers' sources)

/// In-memory koreader-sync-server (`syncs_controller.lua`): server-assigned `timestamp`, `{}` for unknown.
final class FakeKOSyncServer: @unchecked Sendable {
    private let lock = NSLock()
    private var docs: [String: [String: Any]] = [:]
    let user = "alice", key = KOSyncClient.authKey(forPassword: "secret")

    func handle(_ r: MockURLProtocol.Captured) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        guard r.headers["x-auth-user"] == user, r.headers["x-auth-key"] == key else {
            return (401, Data(#"{"message":"Unauthorized"}"#.utf8))
        }
        let path = r.url.path
        if path.hasSuffix("/users/auth") { return (200, Data(#"{"authorized":"OK"}"#.utf8)) }
        if r.method == "PUT", path.hasSuffix("/syncs/progress"),
           var obj = (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any],
           let doc = obj["document"] as? String {
            let ts = Int(Date().timeIntervalSince1970)
            obj["timestamp"] = ts
            docs[doc] = obj
            return (200, try! JSONSerialization.data(withJSONObject: ["document": doc, "timestamp": ts]))
        }
        if r.method == "GET", path.contains("/syncs/progress/") {
            let doc = String(path.split(separator: "/").last ?? "")
            return (200, try! JSONSerialization.data(withJSONObject: docs[doc] ?? [:]))
        }
        return (404, Data())
    }
}

/// In-memory Readest Cloud: Supabase `/auth/v1/token` (rotating refresh tokens) and `/api/sync` with the
/// merge rules of `apps/readest-app/src/pages/api/sync.ts` (insert stamps server time; update only when
/// the client's `updated_at` is strictly newer; the response lists the authoritative rows).
final class FakeReadestServer: @unchecked Sendable {
    private let lock = NSLock()
    let email = "reader@example.com", password = "correct horse"
    let userID = "5f1c7a52-0d4e-4c3b-9a0b-2b8c1d0e6f11"
    var expiresIn = 3600
    private var counter = 0
    private(set) var validAccess: Set<String> = []
    private(set) var validRefresh: Set<String> = []
    private(set) var rows: [String: [String: Any]] = [:]
    private(set) var tokenRequests = 0

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    func expireAllAccessTokens() { lock.lock(); validAccess.removeAll(); lock.unlock() }

    func seed(row: [String: Any]) { lock.lock(); rows[row["book_hash"] as! String] = row; lock.unlock() }

    private func session() -> Data {
        counter += 1
        let access = "access-\(counter)", refresh = "refresh-\(counter)"
        validAccess.insert(access); validRefresh.insert(refresh)
        // Shape of a GoTrue token response (fields the clients read: access_token, refresh_token, expires_in, user.id/email).
        let body: [String: Any] = [
            "access_token": access, "token_type": "bearer", "expires_in": expiresIn,
            "expires_at": Int(Date().timeIntervalSince1970) + expiresIn, "refresh_token": refresh,
            "user": ["id": userID, "aud": "authenticated", "role": "authenticated", "email": email],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func handle(_ r: MockURLProtocol.Captured) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let comps = URLComponents(url: r.url, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let body = (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any] ?? [:]
        if r.url.path == "/auth/v1/token" {
            tokenRequests += 1
            guard r.headers["apikey"] == ReadestConfiguration.readestCloud.anonKey else { return (401, Data(#"{"message":"Invalid API key"}"#.utf8)) }
            if q["grant_type"] == "password" {
                guard body["email"] as? String == email, body["password"] as? String == password else {
                    return (400, Data(#"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#.utf8))
                }
                return (200, session())
            }
            if q["grant_type"] == "refresh_token", let rt = body["refresh_token"] as? String {
                guard validRefresh.remove(rt) != nil else {
                    return (400, Data(#"{"code":400,"error_code":"refresh_token_already_used","msg":"Invalid Refresh Token: Already Used"}"#.utf8))
                }
                return (200, session())
            }
            return (400, Data())
        }
        if r.url.path == "/auth/v1/logout" { return (204, Data()) }
        guard r.url.path == "/api/sync" else { return (404, Data()) }
        let token = (r.headers["authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "")
        guard validAccess.contains(token) else { return (403, Data(#"{"error":"Not authenticated"}"#.utf8)) }
        if r.method == "GET" {
            guard let since = Double(q["since"] ?? "") else {
                return (400, Data(#"{"error":"\"since\" query parameter is required"}"#.utf8))
            }
            let book = q["book"] ?? "", meta = q["meta_hash"] ?? ""
            let found = rows.values.filter { row in
                let updated = Self.iso.date(from: row["updated_at"] as? String ?? "")?.timeIntervalSince1970 ?? 0
                let matches = (!book.isEmpty && row["book_hash"] as? String == book)
                    || (!meta.isEmpty && row["meta_hash"] as? String == meta)
                return matches && updated * 1000 > since
            }
            let out: [String: Any] = ["books": [Any](), "configs": found, "notes": [Any](),
                                      "statBooks": [Any](), "statPages": [Any]()]
            return (200, try! JSONSerialization.data(withJSONObject: out))
        }
        var authoritative: [[String: Any]] = []
        for cfg in (body["configs"] as? [[String: Any]]) ?? [] {
            guard let hash = cfg["bookHash"] as? String else { continue }
            let updatedMs = (cfg["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
            var row: [String: Any] = ["user_id": userID, "book_hash": hash,
                                      "updated_at": Self.iso.string(from: Date(timeIntervalSince1970: updatedMs / 1000))]
            if let m = cfg["metaHash"] { row["meta_hash"] = m }
            if let x = cfg["xpointer"] { row["xpointer"] = x }
            if let p = cfg["progress"] {
                row["progress"] = String(decoding: try! JSONSerialization.data(withJSONObject: p), as: UTF8.self)
            }
            if var existing = rows[hash] {
                let serverMs = (Self.iso.date(from: existing["updated_at"] as? String ?? "")?.timeIntervalSince1970 ?? 0) * 1000
                if updatedMs > serverMs {
                    for (k, v) in row { existing[k] = v } // PostgREST upsert only sets the columns sent
                    rows[hash] = existing
                }
                authoritative.append(rows[hash]!)
            } else {
                row["updated_at"] = Self.iso.string(from: Date()) // insert: server time
                row["created_at"] = row["updated_at"]
                rows[hash] = row
                authoritative.append(row)
            }
        }
        return (200, try! JSONSerialization.data(withJSONObject: ["books": [Any](), "configs": authoritative, "notes": [Any]()]))
    }
}

func mockSession(_ handler: @escaping (MockURLProtocol.Captured) -> (Int, Data)) -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.lock.lock()
    MockURLProtocol.captured = []
    MockURLProtocol.handler = handler
    MockURLProtocol.lock.unlock()
    return URLSession(configuration: cfg)
}

final class KOSyncConnectorConformanceTests: XCTestCase {
    func testConformance() async throws {
        let server = FakeKOSyncServer()
        let session = mockSession(server.handle)
        try await SyncConnectorConformance.verify(ConnectorHarness(
            factory: KOSyncConnectorFactory(),
            form: [KOSyncConnectorFactory.Key.server: "sync.example.com",
                   KOSyncConnectorFactory.Key.user: "alice", KOSyncConnectorFactory.Key.password: "secret"],
            session: session))
    }
}

final class ReadestConnectorConformanceTests: XCTestCase {
    func testConformance() async throws {
        let server = FakeReadestServer()
        let session = mockSession(server.handle)
        try await SyncConnectorConformance.verify(ConnectorHarness(
            factory: ReadestConnectorFactory(),
            form: [ReadestConnectorFactory.Key.email: server.email, ReadestConnectorFactory.Key.password: server.password],
            session: session))
    }
}
