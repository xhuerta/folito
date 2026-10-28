import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReaderCore

/// Tests against a REAL koreader-sync-server. Gated by `KOSYNC_TEST_URL`
/// (e.g. `http://localhost:17200`; see scripts/kosync-server/README.md).
final class KOSyncIntegrationTests: XCTestCase {
    var baseURL: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["KOSYNC_TEST_URL"], let u = URL(string: s) else {
            throw XCTSkip("KOSYNC_TEST_URL not set")
        }
        baseURL = u
    }

    func freshClient(password: String = "pw") async throws -> (KOSyncClient, String) {
        let user = "it\(UInt32.random(in: 100000...999999))\(UInt32.random(in: 100000...999999))"
        let c = KOSyncClient(credentials: KOSyncCredentials(serverURL: baseURL, username: user, password: password))
        try await c.createUser()
        return (c, user)
    }

    func docID() -> String { (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined() }

    func testBadPasswordIsUnauthorized() async throws {
        let (_, user) = try await freshClient(password: "right")
        let bad = KOSyncClient(credentials: KOSyncCredentials(serverURL: baseURL, username: user, password: "wrong"))
        do { try await bad.authorize(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .unauthorized) }
        do { try await bad.pushProgress(KOSyncProgress(document: docID(), progress: "p", percentage: 0.1, device_id: "d")); XCTFail() }
        catch { XCTAssertEqual(error as? KOSyncError, .unauthorized) }
        do { _ = try await bad.fetchProgress(document: docID()); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .unauthorized) }
    }

    func testUnknownDocumentIsNil() async throws {
        let (c, _) = try await freshClient()
        let p = try await c.fetchProgress(document: docID())
        XCTAssertNil(p)
    }

    func testRoundTripFieldsAndServerTimestamp() async throws {
        let (c, _) = try await freshClient()
        let doc = docID()
        let xp = "/body/DocFragment[3]/body/div/p[2]/text().17"
        let before = Int(Date().timeIntervalSince1970)
        try await c.pushProgress(KOSyncProgress(document: doc, progress: xp, percentage: 0.123456789,
                                                device: "WristReader", device_id: "WATCH-1", timestamp: 42))
        let got = try await c.fetchProgress(document: doc)
        XCTAssertEqual(got?.document, doc)
        XCTAssertEqual(got?.progress, xp)   // slashes survive the server's JSON escaping
        XCTAssertEqual(got?.percentage ?? 0, 0.123456789, accuracy: 1e-9)
        XCTAssertEqual(got?.device, "WristReader")
        XCTAssertEqual(got?.device_id, "WATCH-1")
        // Timestamp is assigned by the server (seconds), not taken from the client's `42`.
        let ts = try XCTUnwrap(got?.timestamp)
        XCTAssertGreaterThanOrEqual(ts, before - 5)
        XCTAssertLessThanOrEqual(ts, Int(Date().timeIntervalSince1970) + 5)
    }

    func testUnicodeDeviceNameAndProgress() async throws {
        let (c, _) = try await freshClient()
        let doc = docID()
        try await c.pushProgress(KOSyncProgress(document: doc, progress: "/body/p[1]/text().0", percentage: 0.5,
                                                device: "Uhr von Zoë ⌚️", device_id: "ÄÖ-1"))
        let got = try await c.fetchProgress(document: doc)
        XCTAssertEqual(got?.device, "Uhr von Zoë ⌚️")
        XCTAssertEqual(got?.device_id, "ÄÖ-1")
    }

    /// The server is last-write-wins, even when the new percentage is lower (user re-reads an earlier page).
    func testOverwriteIsLastWriteWinsAndTwoDevices() async throws {
        let (c, _) = try await freshClient()
        let doc = docID()
        try await c.pushProgress(KOSyncProgress(document: doc, progress: "a", percentage: 0.8, device: "Kindle", device_id: "DEV-A"))
        try await c.pushProgress(KOSyncProgress(document: doc, progress: "b", percentage: 0.3, device: "Watch", device_id: "DEV-B"))
        let got = try await c.fetchProgress(document: doc)
        XCTAssertEqual(got?.device_id, "DEV-B")
        XCTAssertEqual(got?.percentage ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(got?.progress, "b")
        // Conflict policy from the viewpoint of each device.
        let policy = DefaultSyncConflictPolicy()
        XCTAssertEqual(policy.decide(localPercentage: 0.1, remote: got, ownDeviceID: "DEV-B"), .keepLocal)
        XCTAssertEqual(policy.decide(localPercentage: 0.1, remote: got, ownDeviceID: "DEV-A"), .offerRemote(got!))
    }

    func testDocumentsAreIndependentAndUsersIsolated() async throws {
        let (c1, _) = try await freshClient()
        let (c2, _) = try await freshClient()
        let d1 = docID(), d2 = docID()
        try await c1.pushProgress(KOSyncProgress(document: d1, progress: "x", percentage: 0.1, device_id: "1"))
        try await c1.pushProgress(KOSyncProgress(document: d2, progress: "y", percentage: 0.2, device_id: "1"))
        let g1 = try await c1.fetchProgress(document: d1)
        let g2 = try await c1.fetchProgress(document: d2)
        XCTAssertEqual(g1?.progress, "x"); XCTAssertEqual(g2?.progress, "y")
        let other = try await c2.fetchProgress(document: d1)
        XCTAssertNil(other)
    }

    /// Server rejects ids containing ':' (it is the redis key separator) with 403 -> permanent error,
    /// which SyncQueue drops instead of retrying forever.
    func testInvalidDocumentIDRejected() async throws {
        let (c, _) = try await freshClient()
        for bad in ["a:b", ""] {
            do { try await c.pushProgress(KOSyncProgress(document: bad, progress: "p", percentage: 0.1, device_id: "d")); XCTFail("accepted \(bad)") }
            catch { XCTAssertEqual(error as? KOSyncError, .server(status: 403), bad) }
        }
        // GET with an unroutable id is a 404 -> nil.
        let p = try await c.fetchProgress(document: "a:b")
        XCTAssertNil(p)
    }

    func testCreateUserInvalidAndDuplicate() async throws {
        let (c, user) = try await freshClient()
        do { try await c.createUser(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .userExists) }
        let colon = KOSyncClient(credentials: KOSyncCredentials(serverURL: baseURL, username: "a:b", password: "pw"))
        do { try await colon.createUser(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .server(status: 403)) }
        let empty = KOSyncClient(credentials: KOSyncCredentials(serverURL: baseURL, username: "", password: "pw"))
        do { try await empty.createUser(); XCTFail() } catch { XCTAssertEqual(error as? KOSyncError, .server(status: 403)) }
        _ = (c, user)
    }

    func testSyncQueueAgainstRealServer() async throws {
        let (c, _) = try await freshClient()
        let q = SyncQueue(client: c, clock: FakeClock())
        let doc = docID()
        await q.enqueue(KOSyncProgress(document: doc, progress: "p1", percentage: 0.1, device_id: "W"))
        await q.enqueue(KOSyncProgress(document: doc, progress: "p2", percentage: 0.2, device_id: "W"))
        await q.enqueue(KOSyncProgress(document: "bad:id", progress: "p", percentage: 0.2, device_id: "W"))
        let r = await q.flush(force: true)
        XCTAssertEqual(r.sent, [doc])
        XCTAssertEqual(r.dropped, ["bad:id"])
        let got = try await c.fetchProgress(document: doc)
        XCTAssertEqual(got?.progress, "p2")
    }

    func testNonKOSyncServerReportsInvalidResponseOrError() async throws {
        // Base URL pointing at a path that is not the API root must not look like success.
        let wrong = KOSyncClient(credentials: KOSyncCredentials(serverURL: baseURL.appendingPathComponent("nope"), username: "x", password: "y"))
        do { try await wrong.authorize(); XCTFail() } catch {
            XCTAssertTrue(error as? KOSyncError == .server(status: 404) || error as? KOSyncError == .invalidResponse, "\(error)")
        }
    }
}
