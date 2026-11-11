import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReaderCore

/// Readest library client (`/api/sync?type=books`, `/api/storage/*`) against a mocked transport. Payloads are
/// the shapes of apps/readest-app/src/pages/api/sync.ts and pages/api/storage/*.ts (docs/READEST_SYNC.md).
final class ReadestLibraryTests: XCTestCase {
    typealias Key = ReadestConnectorFactory.Key
    static let userID = "0a1b2c3d-1111-2222-3333-444455556666"
    static let hash = "5d41402abc4b2a76b9719d911017c592"
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func client(_ handler: @escaping (MockURLProtocol.Captured) -> (Int, Data)) -> ReadestLibraryClient {
        let session = mockSession(handler)
        let s = ReadestSession(accessToken: "tok-1", refreshToken: "ref-1", expiresAt: Date().addingTimeInterval(3600),
                               lifetime: 3600, userID: Self.userID, email: "reader@example.com")
        let store = InMemoryCredentialStore(SyncCredentials([Key.session: s.jsonString()]))
        let auth = ReadestAuth(session: session, store: store)
        return ReadestLibraryClient(session: session, auth: auth, now: { Self.now })
    }

    private var requests: [MockURLProtocol.Captured] {
        MockURLProtocol.lock.lock(); defer { MockURLProtocol.lock.unlock() }; return MockURLProtocol.captured
    }

    private func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
    private func object(_ data: Data?) -> [String: Any] {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    /// A `books` row as Postgres returns it through `GET /api/sync` (snake_case, ISO timestamps).
    static func row(hash: String = hash, uploaded: Bool = true, deleted: Bool = false, format: String = "EPUB",
                    updated: String = "2026-10-29T13:53:43.877+00:00") -> [String: Any] {
        [
            "user_id": userID, "book_hash": hash, "meta_hash": "7d793037a0760186574b0282f2f435e7",
            "format": format, "title": "Alice", "author": "Lewis Carroll", "source_title": "alice",
            "group_id": "g1", "group_name": "Classics", "tags": ["fav"], "progress": [12, 300],
            "reading_status": "reading", "metadata": "{\"language\":\"en\"}",
            "created_at": "2026-10-01T08:00:00+00:00", "updated_at": updated,
            "deleted_at": deleted ? "2026-10-30T08:00:00+00:00" : NSNull(),
            "uploaded_at": uploaded ? "2026-10-02T08:00:00.123456+00:00" : NSNull(),
            "synced_at": "2026-10-29T13:53:44+00:00",
        ]
    }

    // MARK: Request building and parsing

    func testFetchBooksRequestAndParsing() async throws {
        let c = client { _ in (200, self.json(["books": [Self.row(), Self.row(hash: "a", uploaded: false)],
                                               "configs": [], "notes": []])) }
        let books = try await c.fetchBooks()
        let r = requests[0]
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://web.readest.com/api/sync?since=0&type=books")
        XCTAssertEqual(r.headers["authorization"], "Bearer tok-1")
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(books[0].hash, Self.hash)
        XCTAssertEqual(books[0].title, "Alice")
        XCTAssertNotNil(books[0].uploadedAt)
        XCTAssertTrue(books[0].isAvailable)
        XCTAssertFalse(books[1].isAvailable, "a row without uploaded_at has no file")
    }

    func testAvailability() {
        XCTAssertFalse(ReadestCloudBook.parse(Self.row(deleted: true))!.isAvailable)
        XCTAssertFalse(ReadestCloudBook.parse(Self.row(format: "PDF"))!.isAvailable)
        XCTAssertFalse(ReadestCloudBook.parse(Self.row(hash: ReadestCloudBook.placeholderHash))!.isAvailable)
    }

    func testWireRowRoundTripsEveryField() throws {
        let wire = ReadestCloudBook.parse(Self.row())!.wireRow()
        XCTAssertEqual(wire["hash"] as? String, Self.hash)
        XCTAssertEqual(wire["groupName"] as? String, "Classics")
        XCTAssertEqual(wire["tags"] as? [String], ["fav"])
        XCTAssertEqual(wire["progress"] as? [Int], [12, 300])
        XCTAssertEqual(wire["readingStatus"] as? String, "reading")
        XCTAssertEqual((wire["metadata"] as? [String: Any])?["language"] as? String, "en", "metadata goes back as an object")
        XCTAssertEqual((wire["createdAt"] as? NSNumber)?.int64Value, 1_790_841_600_000)
        XCTAssertNil(wire["deletedAt"])
        XCTAssertNil(wire["synced_at"])
    }

    func testDownloadURLRequestAndNotFound() async throws {
        var answer: (Int, Data) = (200, json(["downloadUrl": "https://r2.example/book?sig=1"]))
        let c = client { _ in answer }
        let url = try await c.bookDownloadURL(hash: Self.hash)
        XCTAssertEqual(url?.absoluteString, "https://r2.example/book?sig=1")
        let comps = URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/api/storage/download")
        XCTAssertEqual(comps.queryItems?.first?.value, "\(Self.userID)/Readest/Books/\(Self.hash)/\(Self.hash).epub")

        answer = (404, json(["error": "File not found"]))
        let cover = try await c.coverDownloadURL(hash: Self.hash)
        XCTAssertNil(cover)
        XCTAssertTrue(requests.last!.url.absoluteString.hasSuffix("%2Fcover.png")
                      || requests.last!.url.absoluteString.hasSuffix("/cover.png"))
    }

    func testUploadSendsTicketPutAndRow() async throws {
        let c = client { r in
            switch r.url.path {
            case "/api/storage/upload":
                return (200, self.json(["uploadUrl": "https://r2.example/put?sig=2",
                                        "fileKey": "\(Self.userID)/Readest/Books/\(Self.hash)/\(Self.hash).epub",
                                        "usage": 1000, "quota": 524_288_000]))
            case "/put": return (200, Data())
            default: return (200, self.json(["books": [Self.row()], "configs": [], "notes": []]))
            }
        }
        let epub = Data("PK-epub-bytes".utf8)
        let book = ReadestUploadBook(hash: Self.hash, metaHash: "m1", title: "Alice", author: "Lewis Carroll")
        let result = try await c.uploadBook(epub, book: book, existing: nil)
        XCTAssertEqual(result.hash, Self.hash)

        let r = requests
        XCTAssertEqual(r.map(\.method), ["POST", "PUT", "POST"])
        let ticket = object(r[0].body)
        XCTAssertEqual(ticket["fileName"] as? String, "Readest/Books/\(Self.hash)/\(Self.hash).epub")
        XCTAssertEqual(ticket["fileSize"] as? Int, epub.count)
        XCTAssertEqual(ticket["bookHash"] as? String, Self.hash)
        XCTAssertNil(r[1].headers["authorization"], "presigned PUT carries no bearer token")
        XCTAssertEqual(r[1].body, epub)
        XCTAssertEqual(r[2].url.absoluteString, "https://web.readest.com/api/sync")
        let push = object(r[2].body)
        XCTAssertEqual((push["configs"] as? [Any])?.count, 0)
        let row = (push["books"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(row["hash"] as? String, Self.hash)
        XCTAssertEqual(row["format"] as? String, "EPUB")
        XCTAssertEqual(row["metaHash"] as? String, "m1")
        XCTAssertEqual((row["uploadedAt"] as? NSNumber)?.int64Value, 1_790_000_000_000)
        XCTAssertEqual((row["updatedAt"] as? NSNumber)?.int64Value, 1_790_000_000_000)
        XCTAssertTrue(row["deletedAt"] is NSNull)
    }

    func testUploadCoverSendsTicketAndPut() async throws {
        let c = client { r in
            r.url.path == "/api/storage/upload" ? (200, self.json(["uploadUrl": "https://r2.example/cover"]))
                : (200, Data())
        }
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try await c.uploadCover(png, hash: Self.hash)
        let r = requests
        XCTAssertEqual(r.map(\.method), ["POST", "PUT"])
        let ticket = object(r[0].body)
        XCTAssertEqual(ticket["fileName"] as? String, "Readest/Books/\(Self.hash)/cover.png")
        XCTAssertEqual(ticket["fileSize"] as? Int, png.count)
        XCTAssertEqual(ticket["bookHash"] as? String, Self.hash)
        XCTAssertEqual(r[1].body, png)
        XCTAssertEqual(ReadestFileKey.cover(userID: "u", hash: "h"), "u/Readest/Books/h/cover.png")
    }

    func testUploadOfExistingRowKeepsItsFields() async throws {
        let c = client { r in
            r.url.path == "/api/storage/upload" ? (200, self.json(["uploadUrl": "https://r2.example/put"]))
                : (200, self.json(["books": []]))
        }
        let existing = ReadestCloudBook.parse(Self.row(uploaded: false, deleted: true))!
        _ = try await c.uploadBook(Data([1]), book: ReadestUploadBook(hash: Self.hash, metaHash: nil, title: "x", author: "y"),
                                   existing: existing)
        let row = (object(requests[2].body)["books"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(row["groupName"] as? String, "Classics")
        XCTAssertEqual(row["title"] as? String, "Alice", "the Readest title wins over the local one")
        XCTAssertTrue(row["deletedAt"] is NSNull, "re-upload un-tombstones the row")
    }

    func testDeleteRemovesFilesThenPushesTombstone() async throws {
        let c = client { r in
            switch r.url.path {
            case "/api/storage/list":
                return (200, self.json(["files": [["file_key": "u/Readest/Books/h/Alice.epub", "file_size": 10],
                                                  ["file_key": "u/Readest/Books/h/cover.png", "file_size": 5]],
                                        "total": 2, "page": 1, "pageSize": 100, "totalPages": 1]))
            case "/api/storage/delete": return (200, self.json(["message": "File deleted successfully"]))
            default: return (200, self.json(["books": []]))
            }
        }
        try await c.deleteBook(ReadestCloudBook.parse(Self.row())!)
        let r = requests
        XCTAssertEqual(r.map(\.method), ["GET", "DELETE", "DELETE", "POST"])
        XCTAssertEqual(URLComponents(url: r[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, Self.hash)
        XCTAssertEqual(URLComponents(url: r[2].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                       "u/Readest/Books/h/cover.png")
        let row = (object(r[3].body)["books"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual((row["deletedAt"] as? NSNumber)?.int64Value, 1_790_000_000_000)
        XCTAssertTrue(row["uploadedAt"] is NSNull)
        XCTAssertEqual(row["groupId"] as? String, "g1")
    }

    func testStorageUsage() async throws {
        let c = client { _ in (200, self.json(["totalFiles": 3, "totalSize": 2048, "usage": 2048, "quota": 524_288_000,
                                               "usagePercentage": 0, "byBookHash": []])) }
        let u = try await c.storageUsage()
        XCTAssertEqual(requests[0].url.path, "/api/storage/stats")
        XCTAssertEqual(u, ReadestStorageUsage(usage: 2048, quota: 524_288_000))
        XCTAssertEqual(u.fraction, 2048.0 / 524_288_000, accuracy: 1e-12)
    }

    // MARK: Errors and quota

    func testQuotaExceededIsMapped() async {
        let c = client { _ in (403, self.json(["error": "Insufficient storage quota", "usage": 524_000_000])) }
        do {
            _ = try await c.requestUpload(fileName: "Readest/Books/h/h.epub", fileSize: 10, bookHash: "h")
            XCTFail("expected quota error")
        } catch {
            XCTAssertEqual(error as? ReadestError, .quotaExceeded(usage: 524_000_000))
            XCTAssertEqual((error as? ReadestError)?.syncDisposition, .permanent)
        }
        XCTAssertEqual(requests.count, 1, "a quota 403 must not trigger a token refresh")
    }

    func testErrorMapping() {
        func map(_ status: Int, _ body: [String: Any]) -> ReadestError { ReadestLibraryClient.error(status: status, data: json(body)) }
        XCTAssertEqual(map(403, ["error": "Not authenticated"]), .unauthorized)
        XCTAssertEqual(map(401, [:]), .unauthorized)
        XCTAssertEqual(map(403, ["error": "Unauthorized access to the file"]),
                       .server(status: 403, message: "Unauthorized access to the file"))
        XCTAssertEqual(map(413, ["error": "File too large"]), .fileTooLarge)
        XCTAssertEqual(map(404, ["error": "File not found"]), .notFound)
        XCTAssertEqual(map(429, [:]), .rateLimited)
        XCTAssertEqual(map(500, ["error": "Could not create presigned post"]),
                       .server(status: 500, message: "Could not create presigned post"))
        XCTAssertEqual(ReadestLibraryClient.s3Code(Data("<Error><Code>SignatureDoesNotMatch</Code></Error>".utf8)),
                       "SignatureDoesNotMatch")
    }

    func testPresignedPutFailureCarriesS3Code() async {
        let c = client { _ in (403, Data("<Error><Code>AccessDenied</Code></Error>".utf8)) }
        do {
            try await c.put(Data([1]), to: URL(string: "https://r2.example/put")!)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ReadestError, .server(status: 403, message: "AccessDenied"))
        }
    }

    // MARK: Merge and filter

    func testMergeOfLocalAndCloud() {
        let cloud = [
            ReadestCloudBook.parse(Self.row(hash: "both"))!,
            ReadestCloudBook.parse(Self.row(hash: "old", updated: "2026-01-01T00:00:00Z"))!,
            ReadestCloudBook.parse(Self.row(hash: "new", updated: "2026-10-01T00:00:00Z"))!,
            ReadestCloudBook.parse(Self.row(hash: "gone", deleted: true))!,
            ReadestCloudBook.parse(Self.row(hash: "progressonly", uploaded: false))!,
            ReadestCloudBook.parse(Self.row(hash: "pdf", format: "PDF"))!,
        ]
        let items = LibraryMerge.merge(local: ["local", "both", "progressonly", "local"], hash: { $0 }, cloud: cloud)
        XCTAssertEqual(items.map(\.hash), ["local", "both", "progressonly", "new", "old"])
        XCTAssertEqual(items.map(\.availability), [.localOnly, .localAndReadest, .localOnly, .readestOnly, .readestOnly])
        XCTAssertEqual(items.filter { LibraryFilter.onThisDevice.includes($0.availability) }.map(\.hash),
                       ["local", "both", "progressonly"])
        XCTAssertEqual(items.filter { LibraryFilter.inReadest.includes($0.availability) }.map(\.hash), ["both", "new", "old"])
        XCTAssertEqual(items.filter { LibraryFilter.all.includes($0.availability) }.count, 5)
    }

    // MARK: Issue #103: a book downloaded from Readest listed twice

    /// The Readest app's row for "The Hunger Games", as `GET /api/sync?type=books` returns it.
    static let hungerGamesRow: [String: Any] = [
        "user_id": userID, "book_hash": "9b1c4f0e2d7a6b3c8e5f1a2d4c6b8e0f", "meta_hash": "c2a7d05b8e9f41a3b6d2e4f8a1c3e5d7",
        "format": "EPUB", "title": "The Hunger Games", "author": "Suzanne Collins",
        "source_title": "The Hunger Games - Suzanne Collins", "group_id": NSNull(), "group_name": NSNull(),
        "tags": [String](), "progress": [131, 250], "reading_status": "reading", "cover_hash": "4e2f0a9c1b3d5e7f",
        "metadata": "{\"title\":\"The Hunger Games\",\"author\":\"Suzanne Collins\",\"language\":\"en\"}",
        "page_count": 250, "created_at": "2026-03-14T19:02:11.481+00:00", "updated_at": "2026-11-10T21:40:05.112+00:00",
        "deleted_at": NSNull(), "uploaded_at": "2026-03-14T19:02:15.903+00:00", "synced_at": "2026-11-10T21:40:06+00:00",
    ]

    func testDownloadedBookKeepsReadestsIdAndIsOneRow() throws {
        let row = try XCTUnwrap(ReadestCloudBook.parse(Self.hungerGamesRow))
        // Downloads now take the row's id: matched by hash, one row, in Readest.
        let downloaded = LibraryMatchKeys(hash: row.hash, metaHash: row.metaHash, title: "The Hunger Games",
                                          author: "Suzanne Collins")
        let items = LibraryMerge.merge(local: [downloaded], keys: { $0 }, cloud: [row])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].availability, .localAndReadest)
        XCTAssertFalse(items[0].isLinkedByMetadata)
    }

    func testBookDownloadedWithAnotherFileHashIsLinkedByMetaHash() throws {
        let row = try XCTUnwrap(ReadestCloudBook.parse(Self.hungerGamesRow))
        // A copy downloaded before the fix: its id is the partial MD5 of the served bytes, not `book_hash`.
        let local = LibraryMatchKeys(hash: "e3b0c44298fc1c149afbf4c8996fb924", metaHash: row.metaHash,
                                     title: "The Hunger Games", author: "Suzanne Collins")
        let items = LibraryMerge.merge(local: [local], keys: { $0 }, cloud: [row])
        XCTAssertEqual(items.map(\.hash), [local.hash], "one row, not the local book and a cloud row")
        XCTAssertEqual(items[0].availability, .localAndReadest)
        XCTAssertEqual(items[0].cloud?.hash, row.hash)
        XCTAssertTrue(items[0].isLinkedByMetadata)
    }

    func testBookDownloadedWithAnotherFileAndMetaHashIsLinkedByTitleAndAuthor() throws {
        let row = try XCTUnwrap(ReadestCloudBook.parse(Self.hungerGamesRow))
        let local = LibraryMatchKeys(hash: "e3b0c44298fc1c149afbf4c8996fb924", metaHash: "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f",
                                     title: "the hunger games ", author: "SUZANNE  COLLINS")
        let items = LibraryMerge.merge(local: [local], keys: { $0 }, cloud: [row])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].cloud?.hash, row.hash)
        XCTAssertTrue(items[0].isLinkedByMetadata)
    }

    func testMetadataFallbackNeverStealsARowOrGuesses() throws {
        let row = try XCTUnwrap(ReadestCloudBook.parse(Self.hungerGamesRow))
        // A row matched by hash is not paired again with a second copy.
        let exact = LibraryMatchKeys(hash: row.hash, metaHash: row.metaHash, title: "The Hunger Games", author: "Suzanne Collins")
        let other = LibraryMatchKeys(hash: "1111", metaHash: row.metaHash, title: "The Hunger Games", author: "Suzanne Collins")
        var items = LibraryMerge.merge(local: [other, exact], keys: { $0 }, cloud: [row])
        XCTAssertEqual(items.map(\.availability), [.localOnly, .localAndReadest])
        // Two local copies with the same title (no meta hash): ambiguous, nothing is paired.
        let a = LibraryMatchKeys(hash: "a", title: "The Hunger Games", author: "Suzanne Collins")
        let b = LibraryMatchKeys(hash: "b", title: "The Hunger Games", author: "Suzanne Collins")
        items = LibraryMerge.merge(local: [a, b], keys: { $0 }, cloud: [row])
        XCTAssertEqual(items.map(\.availability), [.localOnly, .localOnly, .readestOnly])
        // Another book by the same author is not paired.
        let c = LibraryMatchKeys(hash: "c", title: "Catching Fire", author: "Suzanne Collins")
        items = LibraryMerge.merge(local: [c], keys: { $0 }, cloud: [row])
        XCTAssertEqual(items.map(\.availability), [.localOnly, .readestOnly])
    }

    func testMergeWithoutReadestIsTheLocalLibrary() {
        let items = LibraryMerge.merge(local: ["a", "b"], hash: { $0 }, cloud: [])
        XCTAssertEqual(items.map(\.availability), [.localOnly, .localOnly])
    }

    func testCloudBookCodableForTheOfflineCache() throws {
        let b = ReadestCloudBook.parse(Self.row())!
        let back = try JSONDecoder().decode(ReadestCloudBook.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
        XCTAssertEqual(back.wireRow()["groupId"] as? String, "g1")
    }
}
