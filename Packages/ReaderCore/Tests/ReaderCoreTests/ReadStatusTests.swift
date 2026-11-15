import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReaderCore

/// Read status ("Finished", issue #113): rules, last-writer-wins merge, wire and persisted form, and the
/// Readest `reading_status` mapping and push (mocked transport; shapes from apps/readest-app/src/pages/api/sync.ts).
final class ReadStatusTests: XCTestCase {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static var ms0: Int64 { 1_790_000_000_000 }

    // MARK: Values

    func testRawValuesAreReadestsReadingStatus() {
        // apps/readest-app/src/types/book.ts: ReadingStatus = 'unread' | 'reading' | 'finished' | 'abandoned'
        XCTAssertEqual(ReadStatus.allCases.map(\.rawValue), ["unread", "reading", "finished", "abandoned"])
    }

    // MARK: Finish rule

    func testReachedEndNeedsTheLastBlocksBottomOnScreen() {
        XCTAssertFalse(ReadStatusRules.reachedEnd(lastBlockMaxY: nil, viewportBottom: 200), "last block not laid out")
        XCTAssertFalse(ReadStatusRules.reachedEnd(lastBlockMaxY: 260, viewportBottom: 200))
        XCTAssertTrue(ReadStatusRules.reachedEnd(lastBlockMaxY: 199, viewportBottom: 200))
        XCTAssertTrue(ReadStatusRules.reachedEnd(lastBlockMaxY: 200 + ReadStatusRules.endTolerance, viewportBottom: 200))
        XCTAssertFalse(ReadStatusRules.reachedEnd(lastBlockMaxY: 201 + ReadStatusRules.endTolerance, viewportBottom: 200))
        XCTAssertFalse(ReadStatusRules.reachedEnd(lastBlockMaxY: .nan, viewportBottom: 200))
    }

    func testOfferOnlyOnArrivingAtTheEndOncePerOpening() {
        typealias R = ReadStatusRules
        let n = 200_000
        XCTAssertTrue(R.shouldOfferFinish(wasAtEnd: false, isAtEnd: true, isFinished: false, alreadyOffered: false, bookCharacters: n))
        XCTAssertFalse(R.shouldOfferFinish(wasAtEnd: true, isAtEnd: true, isFinished: false, alreadyOffered: false, bookCharacters: n),
                       "opened at the end, or still there: no new offer")
        XCTAssertFalse(R.shouldOfferFinish(wasAtEnd: false, isAtEnd: false, isFinished: false, alreadyOffered: false, bookCharacters: n))
        XCTAssertFalse(R.shouldOfferFinish(wasAtEnd: false, isAtEnd: true, isFinished: true, alreadyOffered: false, bookCharacters: n))
        XCTAssertFalse(R.shouldOfferFinish(wasAtEnd: false, isAtEnd: true, isFinished: false, alreadyOffered: true, bookCharacters: n),
                       "declined once: not again in the same opening")
        XCTAssertFalse(R.shouldOfferFinish(wasAtEnd: false, isAtEnd: true, isFinished: false, alreadyOffered: false,
                                           bookCharacters: R.minimumOfferCharacters - 1),
                       "a sample or excerpt a few screens long: no offer")
        XCTAssertTrue(R.shouldOfferFinish(wasAtEnd: false, isAtEnd: true, isFinished: false, alreadyOffered: false,
                                          bookCharacters: R.minimumOfferCharacters))
    }

    // MARK: Manual toggles and stamps

    func testToggleFinishedAndUnread() {
        let finished = ReadStatusRules.toggledFinished(nil, now: Self.t0)
        XCTAssertEqual(finished, ReadStatusMark(status: .finished, stamp: Self.ms0))
        let unread = ReadStatusRules.toggledFinished(finished, now: Self.t0.addingTimeInterval(5))
        XCTAssertEqual(unread.status, .unread)
        XCTAssertEqual(unread.stamp, Self.ms0 + 5000)
        let reading = ReadStatusMark(status: .reading, stamp: 1)
        XCTAssertEqual(ReadStatusRules.toggledFinished(reading, now: Self.t0).status, .finished)
    }

    func testStampIsAlwaysNewerThanTheReplacedMark() {
        let future = ReadStatusMark(status: .finished, stamp: Self.ms0 + 60_000)
        // A clock behind the previous change (other device, skew): still strictly newer, so it wins the merge.
        let next = ReadStatusRules.mark(.unread, now: Self.t0, replacing: future)
        XCTAssertEqual(next.stamp, Self.ms0 + 60_001)
        XCTAssertTrue(ReadStatusMerge.shouldApply(incoming: next, local: future))
        XCTAssertEqual(ReadStatusRules.nextStamp(now: Self.t0, after: nil), Self.ms0)
    }

    func testFinishedLastIsStable() {
        let items = [("a", false), ("b", true), ("c", false), ("d", true), ("e", false)]
        XCTAssertEqual(ReadStatusRules.finishedLast(items) { $0.1 }.map { $0.0 }, ["a", "c", "e", "b", "d"])
    }

    // MARK: Merge

    func testLastWriterWinsTieKeepsLocal() {
        let local = ReadStatusMark(status: .finished, stamp: 10)
        XCTAssertFalse(ReadStatusMerge.shouldApply(incoming: ReadStatusMark(status: .unread, stamp: 10), local: local))
        XCTAssertFalse(ReadStatusMerge.shouldApply(incoming: ReadStatusMark(status: .unread, stamp: 9), local: local))
        XCTAssertTrue(ReadStatusMerge.shouldApply(incoming: ReadStatusMark(status: .unread, stamp: 11), local: local))
        XCTAssertTrue(ReadStatusMerge.shouldApply(incoming: ReadStatusMark(status: .unread, stamp: 0), local: nil))
        XCTAssertEqual(ReadStatusMerge.newer(local, ReadStatusMark(status: .unread, stamp: 10)), local)
        XCTAssertEqual(ReadStatusMerge.newer(nil, local), local)
    }

    func testMergeReportsOnlyChangedBooks() {
        let local = ["a": ReadStatusMark(status: .finished, stamp: 10), "b": ReadStatusMark(status: .unread, stamp: 5)]
        let incoming = ["a": ReadStatusMark(status: .unread, stamp: 9),     // older: ignored
                        "b": ReadStatusMark(status: .finished, stamp: 6),   // newer: taken
                        "c": ReadStatusMark(status: .finished, stamp: 1),   // new book
                        "": ReadStatusMark(status: .finished, stamp: 99)]  // invalid hash
        let (marks, changed) = ReadStatusMerge.merge(local: local, incoming: incoming)
        XCTAssertEqual(changed, ["b", "c"])
        XCTAssertEqual(marks["a"]?.status, .finished)
        XCTAssertEqual(marks["b"]?.status, .finished)
        XCTAssertEqual(marks["c"]?.stamp, 1)
        XCTAssertNil(marks[""])
        // Applying the same marks again (a resend) changes nothing.
        XCTAssertTrue(ReadStatusMerge.merge(local: marks, incoming: incoming).changed.isEmpty)
    }

    func testReconcileWithReadestNeverClobbersANewerRemote() {
        typealias M = ReadStatusMark
        XCTAssertEqual(ReadStatusMerge.reconcile(local: nil, remote: nil), .inSync)
        XCTAssertEqual(ReadStatusMerge.reconcile(local: nil, remote: M(status: .reading, stamp: 0)),
                       .adoptRemote(M(status: .reading, stamp: 0)))
        XCTAssertEqual(ReadStatusMerge.reconcile(local: M(status: .finished, stamp: 5), remote: nil),
                       .pushLocal(M(status: .finished, stamp: 5)))
        XCTAssertEqual(ReadStatusMerge.reconcile(local: M(status: nil, stamp: 5), remote: nil), .inSync)
        // Remote newer: adopted, even when the local one was finished.
        XCTAssertEqual(ReadStatusMerge.reconcile(local: M(status: .finished, stamp: 5), remote: M(status: .unread, stamp: 6)),
                       .adoptRemote(M(status: .unread, stamp: 6)))
        // Local newer and different: pushed.
        XCTAssertEqual(ReadStatusMerge.reconcile(local: M(status: .finished, stamp: 7), remote: M(status: .reading, stamp: 6)),
                       .pushLocal(M(status: .finished, stamp: 7)))
        // Same status, local newer: nothing to write. Same stamp: nothing either.
        XCTAssertEqual(ReadStatusMerge.reconcile(local: M(status: .finished, stamp: 7), remote: M(status: .finished, stamp: 6)), .inSync)
        XCTAssertEqual(ReadStatusMerge.reconcile(local: M(status: .finished, stamp: 6), remote: M(status: .unread, stamp: 6)), .inSync)
        XCTAssertEqual(ReadStatusMerge.reconcile(local: M(status: .finished, stamp: 6), remote: M(status: .finished, stamp: 6)), .inSync)
    }

    // MARK: Persisted and wire form

    func testCodableShortKeysAndTolerantDecoding() throws {
        let data = try JSONEncoder().encode(ReadStatusMark(status: .finished, stamp: 42))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["s"] as? String, "finished")
        XCTAssertEqual((obj["t"] as? NSNumber)?.int64Value, 42)
        func decode(_ json: String) throws -> ReadStatusMark {
            try JSONDecoder().decode(ReadStatusMark.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"s":"wishlist","t":3}"#), ReadStatusMark(status: nil, stamp: 3), "unknown status")
        XCTAssertEqual(try decode(#"{"s":"finished"}"#), ReadStatusMark(status: .finished, stamp: 0), "no stamp")
        XCTAssertEqual(try decode(#"{"t":-5}"#), ReadStatusMark(status: nil, stamp: 0))
        XCTAssertEqual(try decode(#"{"s":7,"t":"x"}"#), ReadStatusMark(status: nil, stamp: 0), "wrong types")
        let cleared = try JSONEncoder().encode(ReadStatusMark(status: nil, stamp: 8))
        XCTAssertEqual(try JSONDecoder().decode(ReadStatusMark.self, from: cleared), ReadStatusMark(status: nil, stamp: 8))
    }

    /// An entry saved before read status existed has no key; the property is optional and decodes as nil.
    func testOlderPersistedEntryDecodesWithoutStatus() throws {
        struct Entry: Codable { var documentHash: String; var readStatus: ReadStatusMark? = nil }
        let old = try JSONDecoder().decode([Entry].self, from: Data(#"[{"documentHash":"h"}]"#.utf8))
        XCTAssertNil(old[0].readStatus)
        let new = try JSONDecoder().decode([Entry].self, from: Data(#"[{"documentHash":"h","readStatus":{"s":"finished","t":1}}]"#.utf8))
        XCTAssertEqual(new[0].readStatus?.isFinished, true)
    }

    func testWireRoundTripAndOlderContexts() {
        let marks = ["h1": ReadStatusMark(status: .finished, stamp: 12), "h2": ReadStatusMark(status: .unread, stamp: 3)]
        let context = ReadStatusSync.context(for: marks)
        XCTAssertTrue(context[ReadStatusSync.key] is String, "a plist-safe JSON string")
        XCTAssertEqual(ReadStatusSync.decode(from: context), marks)
        XCTAssertTrue(ReadStatusSync.context(for: [:]).isEmpty, "no key when there is nothing to say")
        XCTAssertNil(ReadStatusSync.decode(from: ["type": "library", "hashes": ["h1"]]), "contexts of older apps")
        XCTAssertNil(ReadStatusSync.decode(from: [ReadStatusSync.key: "not json"]))
        XCTAssertNil(ReadStatusSync.decode(from: [ReadStatusSync.key: 5]))
        XCTAssertEqual(ReadStatusSync.decode(from: [ReadStatusSync.key: #"{"h":{"s":"later","t":1}}"#])?["h"],
                       ReadStatusMark(status: nil, stamp: 1))
    }

    // MARK: Readest mapping

    func testReadestRowMapping() {
        var row = ReadestLibraryTests.row()
        XCTAssertEqual(ReadestCloudBook.parse(row)?.readStatusMark, ReadStatusMark(status: .reading, stamp: 0),
                       "a status without its own timestamp")
        row["reading_status"] = "finished"
        row["reading_status_updated_at"] = "2026-10-29T13:53:43.877+00:00"
        let mark = ReadestCloudBook.parse(row)?.readStatusMark
        XCTAssertEqual(mark?.status, .finished)
        XCTAssertEqual(mark?.stamp, 1_793_282_023_877)
        row["reading_status"] = NSNull()
        row["reading_status_updated_at"] = NSNull()
        XCTAssertNil(ReadestCloudBook.parse(row)?.readStatusMark, "no status, never set")
        row["reading_status"] = "abandoned"
        XCTAssertEqual(ReadestCloudBook.parse(row)?.readStatusMark?.status, .abandoned)
        XCTAssertNil(ReadestCloudBook(hash: "x", title: "t").readStatusMark)
    }

    func testWithReadStatusKeepsTheRestOfTheRowAndSurvivesTheCache() throws {
        let book = try XCTUnwrap(ReadestCloudBook.parse(ReadestLibraryTests.row()))
        let marked = book.withReadStatus(ReadStatusMark(status: .finished, stamp: Self.ms0 + 123))
        XCTAssertEqual(marked.readStatusMark, ReadStatusMark(status: .finished, stamp: Self.ms0 + 123))
        let wire = marked.wireRow()
        XCTAssertEqual(wire["readingStatus"] as? String, "finished")
        XCTAssertEqual((wire["readingStatusUpdatedAt"] as? NSNumber)?.int64Value, Self.ms0 + 123)
        XCTAssertEqual(wire["groupName"] as? String, "Classics")
        XCTAssertEqual(wire["tags"] as? [String], ["fav"])
        XCTAssertEqual((wire["updatedAt"] as? NSNumber)?.int64Value, (book.wireRow()["updatedAt"] as? NSNumber)?.int64Value)
        // The offline cache (Codable) keeps the mark.
        let cached = try JSONDecoder().decode(ReadestCloudBook.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(cached.readStatusMark, marked.readStatusMark)
        // Clearing writes null, which the wire row leaves out (transformBookToDB turns it into null).
        let cleared = book.withReadStatus(ReadStatusMark(status: nil, stamp: Self.ms0))
        XCTAssertEqual(cleared.readStatusMark, ReadStatusMark(status: nil, stamp: Self.ms0))
        XCTAssertNil(cleared.wireRow()["readingStatus"])
        XCTAssertEqual((cleared.wireRow()["readingStatusUpdatedAt"] as? NSNumber)?.int64Value, Self.ms0)
    }

    // MARK: Readest push

    private func client(_ handler: @escaping (MockURLProtocol.Captured) -> (Int, Data)) -> ReadestLibraryClient {
        let session = mockSession(handler)
        let s = ReadestSession(accessToken: "tok-1", refreshToken: "ref-1", expiresAt: Date().addingTimeInterval(3600),
                               lifetime: 3600, userID: ReadestLibraryTests.userID, email: "reader@example.com")
        let store = InMemoryCredentialStore(SyncCredentials([ReadestConnectorFactory.Key.session: s.jsonString()]))
        return ReadestLibraryClient(session: session, auth: ReadestAuth(session: session, store: store), now: { Self.t0 })
    }

    private var captured: [MockURLProtocol.Captured] {
        MockURLProtocol.lock.lock(); defer { MockURLProtocol.lock.unlock() }; return MockURLProtocol.captured
    }

    private func data(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    /// The server's current row (fetched first) has other fields than the cached copy: the push is built from it.
    func testSetReadingStatusFetchesTheRowThenPushesItWithOnlyTheStatusChanged() async throws {
        var current = ReadestLibraryTests.row(updated: "2026-11-01T10:00:00.000+00:00")
        current["tags"] = ["fav", "new-from-another-device"]
        current["progress"] = [40, 300]
        var answer = current
        answer["reading_status"] = "finished"
        answer["reading_status_updated_at"] = "2026-09-21T14:13:20.123+00:00"
        let c = client { r in
            r.method == "GET" ? (200, self.data(["books": [current]])) : (200, self.data(["books": [answer]]))
        }
        let cached = try XCTUnwrap(ReadestCloudBook.parse(ReadestLibraryTests.row()))
        let result = try await c.setReadingStatus(ReadStatusMark(status: .finished, stamp: Self.ms0 + 123), for: cached)
        XCTAssertEqual(result.readStatusMark, ReadStatusMark(status: .finished, stamp: Self.ms0 + 123))

        let r = captured
        XCTAssertEqual(r.map(\.method), ["GET", "POST"])
        XCTAssertEqual(r[0].url.absoluteString,
                       "https://web.readest.com/api/sync?book=\(ReadestLibraryTests.hash)&since=0&type=books")
        XCTAssertEqual(r[1].url.absoluteString, "https://web.readest.com/api/sync")
        let body = (r[1].body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let row = (body["books"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(row["hash"] as? String, ReadestLibraryTests.hash)
        XCTAssertEqual(row["readingStatus"] as? String, "finished")
        XCTAssertEqual((row["readingStatusUpdatedAt"] as? NSNumber)?.int64Value, Self.ms0 + 123)
        // Every other field is the server's current one, updatedAt included (not bumped): the server keeps its
        // row and grafts only the status.
        XCTAssertEqual((row["updatedAt"] as? NSNumber)?.int64Value, 1_793_527_200_000)
        XCTAssertEqual(row["tags"] as? [String], ["fav", "new-from-another-device"])
        XCTAssertEqual(row["progress"] as? [Int], [40, 300])
        XCTAssertEqual(row["groupId"] as? String, "g1")
        XCTAssertNotNil(row["uploadedAt"])
        XCTAssertNil(row["deletedAt"])
    }

    /// A newer status on the server is never overwritten: nothing is pushed and the server's row comes back.
    func testSetReadingStatusDoesNotPushOverANewerRemoteStatus() async throws {
        var current = ReadestLibraryTests.row()
        current["reading_status"] = "unread"
        current["reading_status_updated_at"] = "2027-01-01T00:00:00+00:00"
        let c = client { _ in (200, self.data(["books": [current]])) }
        let cached = try XCTUnwrap(ReadestCloudBook.parse(ReadestLibraryTests.row()))
        let result = try await c.setReadingStatus(ReadStatusMark(status: .finished, stamp: Self.ms0), for: cached)
        XCTAssertEqual(result.readStatusMark?.status, .unread, "the newer remote status wins")
        XCTAssertEqual(captured.map(\.method), ["GET"], "no write")
    }

    /// The same status with a newer stamp is not sent: the server would not store the timestamp anyway (it only
    /// rewrites a row whose status value changed), so the remote copy is the one to keep.
    func testSetReadingStatusSendsNothingWhenTheStatusIsAlreadySet() async throws {
        var current = ReadestLibraryTests.row()
        current["reading_status"] = "finished"
        current["reading_status_updated_at"] = "2026-01-01T00:00:00+00:00"
        let c = client { _ in (200, self.data(["books": [current]])) }
        let cached = try XCTUnwrap(ReadestCloudBook.parse(ReadestLibraryTests.row()))
        let result = try await c.setReadingStatus(ReadStatusMark(status: .finished, stamp: Self.ms0), for: cached)
        XCTAssertEqual(result.readStatusMark?.status, .finished)
        XCTAssertEqual(captured.map(\.method), ["GET"])
    }

    /// No row on the account (only the placeholder an empty pull returns): the given row is pushed.
    func testSetReadingStatusFallsBackToTheGivenRowAndReturnsTheServersAnswer() async throws {
        var answer = ReadestLibraryTests.row()
        answer["reading_status"] = "unread"
        answer["reading_status_updated_at"] = "2027-01-01T00:00:00+00:00"
        let placeholder = ReadestLibraryTests.row(hash: ReadestCloudBook.placeholderHash, deleted: true)
        let c = client { r in
            r.method == "GET" ? (200, self.data(["books": [placeholder]])) : (200, self.data(["books": [answer]]))
        }
        let book = try XCTUnwrap(ReadestCloudBook.parse(ReadestLibraryTests.row()))
        let result = try await c.setReadingStatus(ReadStatusMark(status: .finished, stamp: Self.ms0), for: book)
        XCTAssertEqual(captured.map(\.method), ["GET", "POST"])
        XCTAssertEqual(result.readStatusMark?.status, .unread, "the server's answer is authoritative")
        // An empty answer falls back to the row as sent.
        let empty = client { _ in (200, self.data(["books": []])) }
        let sent = try await empty.setReadingStatus(ReadStatusMark(status: .finished, stamp: Self.ms0), for: book)
        XCTAssertEqual(sent.readStatusMark, ReadStatusMark(status: .finished, stamp: Self.ms0))
    }
}
