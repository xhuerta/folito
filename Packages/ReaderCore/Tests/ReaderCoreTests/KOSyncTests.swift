import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReaderCore

final class MockURLProtocol: URLProtocol {
    struct Captured { var method: String; var url: URL; var headers: [String: String]; var body: Data? }
    nonisolated(unsafe) static var handler: ((Captured) throws -> (Int, Data))?
    nonisolated(unsafe) static var captured: [Captured] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: 4096); if n <= 0 { break }; d.append(buf, count: n) }
            body = d
        }
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
        let cap = Captured(method: request.httpMethod ?? "", url: request.url!, headers: headers, body: body)
        Self.lock.lock(); Self.captured.append(cap); let h = Self.handler; Self.lock.unlock()
        do {
            let (status, data) = try h!(cap)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class KOSyncClientTests: XCTestCase {
    func makeClient(url: String = "https://sync.example.com", user: String = "alice", pass: String = "secret") -> KOSyncClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.captured = []
        return KOSyncClient(credentials: KOSyncCredentials(serverURL: URL(string: url)!, username: user, password: pass),
                            session: URLSession(configuration: cfg))
    }
    func json(_ s: String) -> Data { Data(s.utf8) }
    // md5("secret")
    let secretMD5 = "5ebe2294ecd0e0f08eab7690d2a6ee69"

    func testMD5Key() { XCTAssertEqual(KOSyncClient.authKey(forPassword: "secret"), secretMD5) }

    func testAuthorizeRequest() async throws {
        let c = makeClient()
        MockURLProtocol.handler = { _ in (200, self.json(#"{"authorized":"OK"}"#)) }
        try await c.authorize()
        let r = MockURLProtocol.captured[0]
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://sync.example.com/users/auth")
        XCTAssertEqual(r.headers["x-auth-user"], "alice")
        XCTAssertEqual(r.headers["x-auth-key"], secretMD5)
        XCTAssertEqual(r.headers["accept"], "application/vnd.koreader.v1+json")
    }

    func testAuthorizeUnauthorizedAndHTML() async throws {
        let c = makeClient()
        MockURLProtocol.handler = { _ in (401, self.json(#"{"message":"Unauthorized"}"#)) }
        do { try await c.authorize(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .unauthorized) }
        MockURLProtocol.handler = { _ in (200, self.json("<html></html>")) }
        do { try await c.authorize(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .invalidResponse) }
    }

    func testCreateUser() async throws {
        let c = makeClient()
        MockURLProtocol.handler = { _ in (201, self.json(#"{"username":"alice"}"#)) }
        try await c.createUser()
        let r = MockURLProtocol.captured[0]
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/users/create")
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.headers["accept"], "application/vnd.koreader.v1+json")
        let body = try JSONSerialization.jsonObject(with: r.body!) as! [String: String]
        XCTAssertEqual(body, ["username": "alice", "password": secretMD5])
        MockURLProtocol.handler = { _ in (402, self.json(#"{"message":"Username is already registered."}"#)) }
        do { try await c.createUser(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .userExists) }
        MockURLProtocol.handler = { _ in (403, Data()) }
        do { try await c.createUser(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .server(status: 403)) }
    }

    func testPushProgress() async throws {
        let c = makeClient()
        MockURLProtocol.handler = { _ in (200, self.json(#"{"document":"abc","timestamp":1700000000}"#)) }
        try await c.pushProgress(KOSyncProgress(document: "abc123", progress: "/body/DocFragment[2]/body/p[1]/text().0",
                                                percentage: 0.25, device: "Folito", device_id: "DEV1", timestamp: 5))
        let r = MockURLProtocol.captured[0]
        XCTAssertEqual(r.method, "PUT")
        XCTAssertEqual(r.url.path, "/syncs/progress")
        XCTAssertEqual(r.headers["x-auth-key"], secretMD5)
        XCTAssertEqual(r.headers["content-type"], "application/json")
        let o = try JSONSerialization.jsonObject(with: r.body!) as! [String: Any]
        XCTAssertEqual(Set(o.keys), ["document", "progress", "percentage", "device", "device_id"])
        XCTAssertEqual(o["document"] as? String, "abc123")
        XCTAssertEqual(o["percentage"] as? Double, 0.25)
        XCTAssertEqual(o["device_id"] as? String, "DEV1")
    }

    func testPushErrors() async {
        let c = makeClient()
        let p = KOSyncProgress(document: "d", progress: "x", percentage: 0.1, device_id: "i")
        for (status, expected) in [(401, KOSyncError.unauthorized), (403, .server(status: 403)), (502, .server(status: 502))] {
            MockURLProtocol.handler = { _ in (status, Data()) }
            do { try await c.pushProgress(p); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, expected) }
        }
    }

    func testFetchProgress() async throws {
        let c = makeClient()
        MockURLProtocol.handler = { _ in (200, self.json(#"{"document":"abc123","progress":"p","percentage":0.5,"device":"KOReader","device_id":"K1","timestamp":1700000000}"#)) }
        let p = try await c.fetchProgress(document: "abc123")
        let r = MockURLProtocol.captured[0]
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.path, "/syncs/progress/abc123")
        XCTAssertNil(r.body)
        XCTAssertEqual(p, KOSyncProgress(document: "abc123", progress: "p", percentage: 0.5, device: "KOReader", device_id: "K1", timestamp: 1700000000))
    }

    func testFetchEmptyAndNotFoundAreNil() async throws {
        let c = makeClient()
        for (status, body) in [(200, "{}"), (200, ""), (404, #"{"message":"x"}"#)] {
            MockURLProtocol.handler = { _ in (status, self.json(body)) }
            let p = try await c.fetchProgress(document: "abc")
            XCTAssertNil(p)
        }
        MockURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await c.fetchProgress(document: "abc"); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .unauthorized) }
    }

    func testFetchWithoutDocumentFieldUsesRequested() async throws {
        let c = makeClient()
        MockURLProtocol.handler = { _ in (200, self.json(#"{"progress":"p","percentage":0.3,"device":"d","device_id":"i"}"#)) }
        let p = try await c.fetchProgress(document: "abc")
        XCTAssertEqual(p?.document, "abc")
        XCTAssertNil(p?.timestamp)
    }

    func testBasePathAndTrailingSlash() async throws {
        for base in ["https://h.example.com/kosync/", "https://h.example.com/kosync"] {
            let c = makeClient(url: base)
            MockURLProtocol.handler = { _ in (200, self.json("{}")) }
            try await c.authorize()
            XCTAssertEqual(MockURLProtocol.captured[0].url.absoluteString, "https://h.example.com/kosync/users/auth")
        }
    }

    func testOfflineMapping() async {
        let c = makeClient()
        for code in [URLError.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost] {
            MockURLProtocol.handler = { _ in throw URLError(code) }
            do { try await c.authorize(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .offline, "\(code)") }
        }
    }

    func testDefaultServer() {
        XCTAssertEqual(KOSyncCredentials(username: "a", password: "b").serverURL.absoluteString, "https://sync.koreader.rocks")
    }

    // Optional: KOSYNC_TEST_URL=http://localhost:8081 (registration enabled)
    func testIntegration() async throws {
        guard let url = ProcessInfo.processInfo.environment["KOSYNC_TEST_URL"] else { throw XCTSkip("KOSYNC_TEST_URL not set") }
        let user = "u\(Int.random(in: 100000...999999))"
        let c = KOSyncClient(credentials: KOSyncCredentials(serverURL: URL(string: url)!, username: user, password: "pw"))
        do { try await c.authorize(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .unauthorized) }
        try await c.createUser()
        do { try await c.createUser(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .userExists) }
        try await c.authorize()
        let doc = "0123456789abcdef0123456789abcdef"
        let none = try await c.fetchProgress(document: doc)
        XCTAssertNil(none)
        try await c.pushProgress(KOSyncProgress(document: doc, progress: "/body/p", percentage: 0.42, device: "WR", device_id: "D"))
        let got = try await c.fetchProgress(document: doc)
        XCTAssertEqual(got?.percentage ?? 0, 0.42, accuracy: 1e-9)
        XCTAssertEqual(got?.device_id, "D")
        XCTAssertNotNil(got?.timestamp)
    }
}

final class KOSyncPolicyTests: XCTestCase {
    func remote(_ pct: Double, _ dev: String = "other") -> KOSyncProgress {
        KOSyncProgress(document: "d", progress: "p", percentage: pct, device_id: dev)
    }
    func testPolicy() {
        let p = DefaultSyncConflictPolicy()
        XCTAssertEqual(p.decide(localPercentage: 0.1, remote: nil, ownDeviceID: "me"), .keepLocal)
        XCTAssertEqual(p.decide(localPercentage: 0.1, remote: remote(0.3), ownDeviceID: "me"), .offerRemote(remote(0.3)))
        XCTAssertEqual(p.decide(localPercentage: 0.1, remote: remote(0.3, "me"), ownDeviceID: "me"), .keepLocal)
        XCTAssertEqual(p.decide(localPercentage: 0.3, remote: remote(0.1), ownDeviceID: "me"), .keepLocal)
        XCTAssertEqual(p.decide(localPercentage: 0.5, remote: remote(0.5), ownDeviceID: "me"), .keepLocal)
        XCTAssertEqual(p.decide(localPercentage: 0.5, remote: remote(0.504), ownDeviceID: "me"), .keepLocal)
        XCTAssertEqual(p.decide(localPercentage: 0.5, remote: remote(0.506), ownDeviceID: "me"), .offerRemote(remote(0.506)))
    }
}

// MARK: - SyncQueue

final class FakeClock: SyncClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    private(set) var sleeps: [TimeInterval] = []
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func sleep(seconds: TimeInterval) async throws {
        lock.lock(); sleeps.append(seconds); t = t.addingTimeInterval(seconds); lock.unlock()
        await Task.yield()
    }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

final class FakeClient: KOSyncClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    var failures: [Error] = []
    private(set) var pushed: [KOSyncProgress] = []
    func authorize() async throws {}
    func createUser() async throws {}
    func fetchProgress(document: String) async throws -> KOSyncProgress? { nil }
    func pushProgress(_ progress: KOSyncProgress) async throws {
        lock.lock(); defer { lock.unlock() }
        if !failures.isEmpty { throw failures.removeFirst() }
        pushed.append(progress)
    }
}

final class SyncQueueTests: XCTestCase {
    func prog(_ doc: String, _ pct: Double) -> KOSyncProgress {
        KOSyncProgress(document: doc, progress: "p\(pct)", percentage: pct, device_id: "me")
    }

    func testKeepsLatestPerDocument() async {
        let client = FakeClient()
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog("a", 0.1)); await q.enqueue(prog("a", 0.2)); await q.enqueue(prog("b", 0.3))
        let r = await q.flush()
        XCTAssertEqual(r.sent, ["a", "b"])
        XCTAssertEqual(client.pushed.map(\.percentage), [0.2, 0.3])
        let pending = await q.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func testBackoffAndRetry() async {
        let client = FakeClient(); let clock = FakeClock()
        client.failures = [KOSyncError.offline, KOSyncError.offline]
        let q = SyncQueue(client: client, clock: clock)
        await q.enqueue(prog("a", 0.1))
        var r = await q.flush()
        XCTAssertEqual(r.retained, ["a"])
        r = await q.flush() // not due yet
        XCTAssertEqual(r.retained, ["a"]); XCTAssertTrue(client.pushed.isEmpty)
        clock.advance(2)
        r = await q.flush()
        XCTAssertEqual(r.retained, ["a"])
        let attempts = await q.pending.first?.attempts
        XCTAssertEqual(attempts, 2)
        clock.advance(4)
        r = await q.flush()
        XCTAssertEqual(r.sent, ["a"])
    }

    func testBackoffCurve() async {
        var cfg = SyncQueue.Config(); cfg.baseBackoff = 2; cfg.maxBackoff = 10
        let q = SyncQueue(client: FakeClient(), clock: FakeClock(), config: cfg)
        let v = [await q.backoff(forAttempt: 1), await q.backoff(forAttempt: 2), await q.backoff(forAttempt: 3), await q.backoff(forAttempt: 9)]
        XCTAssertEqual(v, [2, 4, 8, 10])
    }

    func testUnauthorizedRetainsPermanentDrops() async {
        let client = FakeClient()
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog("a", 0.1))
        client.failures = [KOSyncError.unauthorized]
        var r = await q.flush(force: true)
        XCTAssertTrue(r.unauthorized); XCTAssertEqual(r.retained, ["a"])
        client.failures = [KOSyncError.server(status: 403)]
        r = await q.flush(force: true)
        XCTAssertEqual(r.dropped, ["a"])
        let pending = await q.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func testPersistenceRoundTrip() async throws {
        let q1 = SyncQueue(client: FakeClient(), clock: FakeClock())
        await q1.enqueue(prog("a", 0.4))
        let data = try await q1.snapshot()
        let client = FakeClient()
        let q2 = SyncQueue(client: client, clock: FakeClock(), restoring: data)
        let r = await q2.flush(force: true)
        XCTAssertEqual(r.sent, ["a"]); XCTAssertEqual(client.pushed.first?.percentage, 0.4)
    }

    func testScheduleDebouncesAndRetriesInBackground() async throws {
        let client = FakeClient(); let clock = FakeClock()
        client.failures = [KOSyncError.offline]
        let q = SyncQueue(client: client, clock: clock)
        await q.schedule(prog("a", 0.1))
        await q.schedule(prog("a", 0.2))
        for _ in 0..<200 where !(await q.pending.isEmpty) { try await Task.sleep(nanoseconds: 5_000_000) }
        let pending = await q.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(client.pushed.map(\.percentage), [0.2])
        XCTAssertEqual(clock.sleeps.first, 5)
    }
}
