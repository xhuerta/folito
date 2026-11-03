import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReaderCore

private struct FixedClock: ReadestClock {
    let date: Date
    func now() -> Date { date }
}

final class ReadestSyncTests: XCTestCase {
    typealias Key = ReadestConnectorFactory.Key

    private func signedIn(_ server: FakeReadestServer, clock: ReadestClock = SystemReadestClock())
        async throws -> (ReadestConnector, InMemoryCredentialStore) {
        let session = mockSession(server.handle)
        let creds = try await ReadestConnectorFactory().signIn(
            fields: [Key.email: server.email, Key.password: server.password], session: session)
        let store = InMemoryCredentialStore(creds)
        let auth = ReadestAuth(session: session, store: store, clock: clock)
        return (ReadestConnector(auth: auth, client: ReadestSyncClient(session: session, auth: auth), clock: clock), store)
    }

    private var requests: [MockURLProtocol.Captured] {
        MockURLProtocol.lock.lock(); defer { MockURLProtocol.lock.unlock() }; return MockURLProtocol.captured
    }

    // MARK: Auth (supabase-auth-api.json)

    func testPasswordGrantRequestShape() async throws {
        let server = FakeReadestServer()
        let session = mockSession(server.handle)
        let creds = try await ReadestConnectorFactory().signIn(
            fields: [Key.email: "  \(server.email) ", Key.password: server.password], session: session)
        let r = requests[0]
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://vbsyxfusjjqdxkjqlysc.supabase.co/auth/v1/token?grant_type=password")
        XCTAssertEqual(r.headers["apikey"], ReadestConfiguration.readestCloud.anonKey)
        XCTAssertNil(r.headers["authorization"])
        let body = try JSONSerialization.jsonObject(with: r.body ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["email": server.email, "password": server.password])
        XCTAssertEqual(creds[Key.email], server.email)
        XCTAssertNil(creds[Key.password], "the password is never stored")
        let s = try XCTUnwrap(creds[Key.session].flatMap(ReadestSession.init(jsonString:)))
        XCTAssertEqual(s.userID, server.userID)
        XCTAssertEqual(s.lifetime, 3600)
    }

    func testAnonKeyIsThePublicAnonRoleJWT() throws {
        let parts = ReadestConfiguration.readestCloud.anonKey.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        let claims = try JSONSerialization.jsonObject(with: Data(base64Encoded: payload)!) as? [String: Any]
        XCTAssertEqual(claims?["role"] as? String, "anon")
        XCTAssertEqual(claims?["ref"] as? String, "vbsyxfusjjqdxkjqlysc")
    }

    func testWrongPasswordIsInvalidCredentials() async {
        let server = FakeReadestServer()
        let session = mockSession(server.handle)
        do {
            _ = try await ReadestConnectorFactory().signIn(fields: [Key.email: server.email, Key.password: "nope"], session: session)
            XCTFail()
        } catch { XCTAssertEqual(error as? ReadestError, .invalidCredentials) }
    }

    func testExpiringTokenIsRefreshedOnceAndRotationPersisted() async throws {
        let server = FakeReadestServer()
        server.expiresIn = 100 // margin = max(60, lifetime/2) = 60 s
        let (c, store) = try await signedIn(server, clock: FixedClock(date: Date().addingTimeInterval(50)))
        let before = try XCTUnwrap(store.load()?[Key.session].flatMap(ReadestSession.init(jsonString:)))
        async let a: ReadingPosition? = c.fetchProgress(for: BookIdentity(partialMD5: "a"))
        async let b: ReadingPosition? = c.fetchProgress(for: BookIdentity(partialMD5: "b"))
        _ = try await (a, b)
        XCTAssertEqual(server.tokenRequests, 2, "sign-in + ONE shared refresh (refresh tokens are single use)")
        let after = try XCTUnwrap(store.load()?[Key.session].flatMap(ReadestSession.init(jsonString:)))
        XCTAssertNotEqual(after.refreshToken, before.refreshToken, "the rotated refresh token is saved")
        let refresh = requests.first { $0.url.query == "grant_type=refresh_token" }
        let body = try JSONSerialization.jsonObject(with: refresh?.body ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["refresh_token": before.refreshToken])
    }

    func testNotAuthenticated403RefreshesAndRetriesOnce() async throws {
        let server = FakeReadestServer()
        let (c, _) = try await signedIn(server)
        server.expireAllAccessTokens()
        _ = try await c.fetchProgress(for: BookIdentity(partialMD5: "abc"))
        let api = requests.filter { $0.url.path == "/api/sync" }
        XCTAssertEqual(api.count, 2)
        XCTAssertNotEqual(api[0].headers["authorization"], api[1].headers["authorization"])
    }

    func testRejectedRefreshTokenRequiresSignInAndStopsRequests() async throws {
        let server = FakeReadestServer()
        let (c, store) = try await signedIn(server)
        // Another client already used (rotated) our refresh token.
        var creds = try XCTUnwrap(store.load())
        var s = try XCTUnwrap(creds[Key.session].flatMap(ReadestSession.init(jsonString:)))
        s.refreshToken = "refresh-used-elsewhere"
        creds[Key.session] = s.jsonString()
        store.save(creds)
        server.expireAllAccessTokens()
        do { _ = try await c.fetchProgress(for: BookIdentity(partialMD5: "x")); XCTFail() }
        catch { XCTAssertEqual(error as? ReadestError, .unauthorized) }
        XCTAssertEqual(store.load()?[Key.authRequired], "1")
        XCTAssertEqual(store.load()?[Key.email], server.email, "the account stays visible")
        let count = requests.count
        do { try await c.pushProgress(ReadingPosition(xpointer: "/body/p", percentage: 0.1), for: BookIdentity(partialMD5: "x")); XCTFail() }
        catch { XCTAssertEqual(SyncErrors.disposition(of: error), .unauthorized) }
        XCTAssertEqual(requests.count, count, "a dead session sends nothing")
    }

    // MARK: Sync API (readest-sync-api.json)

    func testPushBodyMatchesKoreaderPlugin() async throws {
        let server = FakeReadestServer()
        let (c, _) = try await signedIn(server)
        let at = Date(timeIntervalSince1970: 1_761_000_000.123)
        let book = BookIdentity(partialMD5: "5d41402abc4b2a76b9719d911017c592", metaHash: "7d793037a0760186574b0282f2f435e7")
        try await c.pushProgress(ReadingPosition(xpointer: "/body/DocFragment[12]/body/div/p[3]/text().42",
                                                 percentage: 0.4, page: 120, pageCount: 300, timestamp: at), for: book)
        let r = try XCTUnwrap(requests.last)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://web.readest.com/api/sync")
        XCTAssertTrue(r.headers["authorization"]?.hasPrefix("Bearer ") == true)
        XCTAssertNil(r.headers["apikey"], "the Readest API takes only the bearer token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: r.body ?? Data()) as? [String: Any])
        XCTAssertEqual((body["books"] as? [Any])?.count, 0)
        XCTAssertEqual((body["notes"] as? [Any])?.count, 0)
        let cfg = try XCTUnwrap((body["configs"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(cfg.keys), ["bookHash", "metaHash", "progress", "xpointer", "updatedAt"],
                       "never `location`: the Readest apps' CFI must stay untouched")
        XCTAssertEqual(cfg["bookHash"] as? String, book.partialMD5)
        XCTAssertEqual(cfg["metaHash"] as? String, book.metaHash)
        XCTAssertEqual(cfg["xpointer"] as? String, "/body/DocFragment[12]/body/div/p[3]/text().42")
        XCTAssertEqual(cfg["progress"] as? [Int], [120, 300])
        XCTAssertEqual((cfg["updatedAt"] as? NSNumber)?.int64Value, 1_761_000_000_123, "epoch ms of when it was read")
    }

    func testPullRequestAndRealRowShape() async throws {
        let server = FakeReadestServer()
        // A row as written by readest.koplugin and returned by `select('*')` from book_configs.
        server.seed(row: ["user_id": server.userID, "book_hash": "5d41402abc4b2a76b9719d911017c592",
                          "meta_hash": "7d793037a0760186574b0282f2f435e7", "location": NSNull(),
                          "xpointer": "/body/DocFragment[5]/body/p[99]/text().4", "progress": "[80,100]",
                          "rsvp_position": NSNull(), "search_config": NSNull(), "view_settings": NSNull(),
                          "created_at": "2026-10-01T08:00:00.000Z", "updated_at": "2026-10-29T13:53:43.877Z",
                          "deleted_at": NSNull()])
        let (c, _) = try await signedIn(server)
        let p = try await c.fetchProgress(for: BookIdentity(partialMD5: "5d41402abc4b2a76b9719d911017c592",
                                                            metaHash: "7d793037a0760186574b0282f2f435e7"))
        let r = try XCTUnwrap(requests.last)
        XCTAssertEqual(r.method, "GET")
        let q = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") }),
                       ["since": "0", "type": "configs", "book": "5d41402abc4b2a76b9719d911017c592",
                        "meta_hash": "7d793037a0760186574b0282f2f435e7"])
        XCTAssertEqual(p?.xpointer, "/body/DocFragment[5]/body/p[99]/text().4")
        XCTAssertEqual(p?.percentage ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(p?.page, 80); XCTAssertEqual(p?.pageCount, 100)
        XCTAssertEqual(p?.timestamp?.timeIntervalSince1970 ?? 0, 1_793_282_023.877, accuracy: 0.001)
        XCTAssertEqual(p?.deviceID, "")
    }

    func testPostgresTimestampFormats() {
        XCTAssertEqual(ReadestHTTP.date("2026-10-29 13:53:43.877123+00")?.timeIntervalSince1970 ?? 0,
                       ReadestHTTP.date("2026-10-29T13:53:43.877+00:00")?.timeIntervalSince1970 ?? 1, accuracy: 0.001)
        XCTAssertNotNil(ReadestHTTP.date("2026-10-29T13:53:43+00:00"))
        XCTAssertEqual(ReadestHTTP.date(NSNumber(value: 1_761_000_000_123))?.timeIntervalSince1970 ?? 0, 1_761_000_000.123, accuracy: 0.001)
    }

    // MARK: Mapping

    func testMapperPrefersExactCopyAndTakesOnlyTheFractionFromAFurtherSibling() {
        let book = BookIdentity(partialMD5: "exact", metaHash: "meta")
        let exact = ReadestBookConfig(bookHash: "exact", metaHash: "meta", xpointer: "/body/DocFragment[2]/body/p",
                                      progress: [20, 100], updatedAt: Date(timeIntervalSince1970: 10))
        let sibling = ReadestBookConfig(bookHash: "other-file", metaHash: "meta", xpointer: "/body/DocFragment[9]/body/p",
                                        progress: [60, 100], updatedAt: Date(timeIntervalSince1970: 5))
        let p = ReadestProgressMapper.position(from: [exact, sibling], book: book)
        XCTAssertEqual(p?.xpointer, "", "a sibling's XPointer belongs to a different file")
        XCTAssertEqual(p?.percentage ?? 0, 0.6, accuracy: 1e-9)
        let behind = ReadestBookConfig(bookHash: "other-file", metaHash: "meta", progress: [10, 100])
        XCTAssertEqual(ReadestProgressMapper.position(from: [exact, behind], book: book)?.xpointer,
                       "/body/DocFragment[2]/body/p")
        XCTAssertNil(ReadestProgressMapper.position(from: [], book: book))
        let tomb = ReadestBookConfig(bookHash: "exact", xpointer: "/body/p", deletedAt: Date())
        XCTAssertNil(ReadestProgressMapper.position(from: [tomb], book: book))
    }

    func testMapperReadsReadestAppRowsWithoutXPointer() {
        // The Readest apps send xpointer "" when CFI -> XPointer conversion fails; only progress is usable.
        let row = ReadestBookConfig.parse(["book_hash": "h", "xpointer": "", "progress": "[33,300]",
                                           "location": "epubcfi(/6/24!/4/2/1:0)", "updated_at": "2026-10-29T10:00:00Z"])
        let p = ReadestProgressMapper.position(from: [row!], book: BookIdentity(partialMD5: "h"))
        XCTAssertEqual(p?.xpointer, "")
        XCTAssertEqual(p?.percentage ?? 0, 0.11, accuracy: 1e-9)
    }

    func testMapperProgressPair() {
        let book = BookIdentity(partialMD5: "h")
        let now = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(ReadestProgressMapper.config(for: ReadingPosition(xpointer: "x", percentage: 0.5, page: 7, pageCount: 9),
                                                    book: book, now: now).progress, [7, 9])
        XCTAssertEqual(ReadestProgressMapper.config(for: ReadingPosition(xpointer: "x", percentage: 0.4567),
                                                    book: book, now: now).progress, [457, 1000])
        XCTAssertEqual(ReadestProgressMapper.config(for: ReadingPosition(xpointer: "x", percentage: 0),
                                                    book: book, now: now).progress, [1, 1000],
                       "Readest ignores progress[0] == 0")
        XCTAssertEqual(ReadestProgressMapper.config(for: ReadingPosition(xpointer: "x", percentage: .nan),
                                                    book: book, now: now).updatedAt, now)
    }

    func testServerKeepsNewerPositionOnStalePush() async throws {
        let server = FakeReadestServer()
        let (c, _) = try await signedIn(server)
        let book = BookIdentity(partialMD5: "lww")
        try await c.pushProgress(ReadingPosition(xpointer: "/body/new", percentage: 0.7, timestamp: Date()), for: book)
        try await c.pushProgress(ReadingPosition(xpointer: "/body/old", percentage: 0.2,
                                                 timestamp: Date().addingTimeInterval(-3600)), for: book)
        let remote = try await c.fetchProgress(for: book)
        XCTAssertEqual(remote?.xpointer, "/body/new")
    }

    // MARK: Errors and wiring

    func testErrorDispositions() {
        XCTAssertEqual(SyncErrors.disposition(of: ReadestError.offline), .transient)
        XCTAssertEqual(SyncErrors.disposition(of: ReadestError.rateLimited), .transient)
        XCTAssertEqual(SyncErrors.disposition(of: ReadestError.server(status: 503, message: nil)), .transient)
        XCTAssertEqual(SyncErrors.disposition(of: ReadestError.server(status: 403, message: "Quota exceeded")), .permanent)
        XCTAssertEqual(SyncErrors.disposition(of: ReadestError.unauthorized), .unauthorized)
        XCTAssertEqual(SyncErrors.disposition(of: KOSyncError.unauthorized), .unauthorized)
        XCTAssertEqual(SyncErrors.disposition(of: KOSyncError.server(status: 403)), .permanent)
        XCTAssertEqual(SyncErrors.disposition(of: URLError(.timedOut)), .transient)
        XCTAssertTrue(SyncErrors.isOffline(ReadestError.offline))
    }

    func testRegistryAndWire() {
        let reg = SyncConnectorRegistry.standard
        XCTAssertEqual(reg.descriptors.map(\.id), ["kosync", "readest"])
        XCTAssertNotNil(reg.factory(id: "readest"))
        XCTAssertNil(reg.factory(id: "nope"))
        XCTAssertTrue(reg.allStorageKeys.contains("kosync_password"))
        XCTAssertTrue(reg.allStorageKeys.contains("readest_session"))
        let creds = SyncCredentials(["readest_email": "a@b.c", "readest_session": "{\"x\":1}"])
        let info = SyncSettingsWire.encode(connectorID: "readest", credentials: creds)
        XCTAssertEqual(info[SyncSettingsWire.versionKey] as? Int, 2)
        let decoded = SyncSettingsWire.decode(info)
        XCTAssertEqual(decoded?.0, "readest")
        XCTAssertEqual(decoded?.1, creds)
        XCTAssertNil(SyncSettingsWire.decode(["kosync_user": "alice"]))
    }

    func testLegacyQueueStateDecodesAsKOSyncEntries() throws {
        // `sync.queue.v1` as persisted by builds before connectors.
        let legacy = #"[{"progress":{"document":"abc","progress":"/body/p","percentage":0.5,"device":"Watch","device_id":"w1","timestamp":1000},"attempts":2,"nextAttempt":0}]"#
        let list = try JSONDecoder().decode([PendingProgress].self, from: Data(legacy.utf8))
        XCTAssertEqual(list.first?.entry.connectorID, "kosync")
        XCTAssertEqual(list.first?.entry.book.partialMD5, "abc")
        XCTAssertEqual(list.first?.entry.position.timestamp, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(list.first?.progress.device_id, "w1")
        XCTAssertEqual(list.first?.attempts, 2)
    }

    func testRetainOnlyDropsOtherConnectors() async {
        let q = SyncQueue(connector: UnconfiguredConnector())
        await q.enqueue(SyncEntry(connectorID: "kosync", book: BookIdentity(partialMD5: "a"),
                                  position: ReadingPosition(xpointer: "x", percentage: 0.1)))
        await q.enqueue(SyncEntry(connectorID: "readest", book: BookIdentity(partialMD5: "b"),
                                  position: ReadingPosition(xpointer: "y", percentage: 0.2)))
        await q.retainOnly(connectorID: "readest")
        let pending = await q.pending
        XCTAssertEqual(pending.map(\.entry.book.key), ["b"])
        let r = await q.flush(force: true)
        XCTAssertTrue(r.unauthorized, "without a configured connector entries are kept, not dropped")
        XCTAssertEqual(r.retained, ["b"])
    }

    func testNeutralConflictPolicy() {
        let policy = DefaultSyncConflictPolicy()
        let readest = ReadingPosition(xpointer: "/body/p", percentage: 0.5, deviceID: "")
        XCTAssertEqual(policy.decide(localPercentage: 0.2, remote: readest, ownDeviceID: "watch"), .offerRemote(readest))
        XCTAssertEqual(policy.decide(localPercentage: 0.5, remote: readest, ownDeviceID: "watch"), .keepLocal)
        let mine = ReadingPosition(xpointer: "/body/p", percentage: 0.9, deviceID: "watch")
        XCTAssertEqual(policy.decide(localPercentage: 0.2, remote: mine, ownDeviceID: "watch"), .keepLocal)
        XCTAssertEqual(policy.decide(localPercentage: 0.2, remote: nil as ReadingPosition?, ownDeviceID: "watch"), .keepLocal)
    }
}
