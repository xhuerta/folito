import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReaderCore

/// Live tests against Readest Cloud. Skipped unless READEST_TEST_EMAIL and READEST_TEST_PASSWORD are set
/// (CI: repository secrets of the same names). Use a dedicated test account: the tests write one
/// `book_configs` row for a fixed fake book hash that no real file has. Credentials are never printed.
final class ReadestIntegrationTests: XCTestCase {
    /// Not the partial MD5 of any real EPUB, so the row never moves a real book.
    static let testBook = BookIdentity(partialMD5: "f0111070000000000000000000000001",
                                       metaHash: "f0111070000000000000000000000002")
    var form: [String: String] = [:]

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["READEST_TEST_EMAIL"], !email.isEmpty,
              let password = env["READEST_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("READEST_TEST_EMAIL / READEST_TEST_PASSWORD not set")
        }
        form = [ReadestConnectorFactory.Key.email: email, ReadestConnectorFactory.Key.password: password]
    }

    func testSignInPushPullAndLastWriterWins() async throws {
        let factory = ReadestConnectorFactory()
        let creds = try await factory.signIn(fields: form, session: .shared)
        let store = InMemoryCredentialStore(creds)
        let connector = factory.makeConnector(credentials: creds, store: store, session: .shared)
        try await connector.authorize()

        let now = Date()
        let xp = "/body/DocFragment[3]/body/p[\(Int.random(in: 2...999))]/text().7"
        try await connector.pushProgress(ReadingPosition(xpointer: xp, percentage: 0.42, page: 42, pageCount: 100,
                                                         timestamp: now), for: Self.testBook)
        let back = try await connector.fetchProgress(for: Self.testBook)
        XCTAssertEqual(back?.xpointer, xp)
        XCTAssertEqual(back?.percentage ?? 0, 0.42, accuracy: 0.001)

        // An older position must not overwrite it (server-side last-writer-wins on updated_at).
        try await connector.pushProgress(ReadingPosition(xpointer: "/body/DocFragment[1]/body/p", percentage: 0.01,
                                                         timestamp: now.addingTimeInterval(-3600)), for: Self.testBook)
        let still = try await connector.fetchProgress(for: Self.testBook)
        XCTAssertEqual(still?.xpointer, xp)

        // A forced refresh rotates the token and the new session keeps working.
        let auth = ReadestAuth(session: .shared, store: store)
        _ = try await auth.validAccessToken(forceRefresh: true)
        let again = factory.makeConnector(credentials: store.load()!, store: store, session: .shared)
        try await again.authorize()
        await factory.signOut(credentials: store.load()!, session: .shared)
    }

    /// Library round trip with a real, tiny EPUB (the English sample book): list, upload, find it listed,
    /// download it byte for byte, then delete it from Readest (files and row) and check it is gone. The
    /// deletion runs even when an assertion fails, so the test account is left as it was.
    func testLibraryUploadListDownloadDelete() async throws {
        let factory = ReadestConnectorFactory()
        let creds = try await factory.signIn(fields: form, session: .shared)
        let store = InMemoryCredentialStore(creds)
        let auth = ReadestAuth(session: .shared, store: store)
        let client = ReadestLibraryClient(auth: auth)

        let epubURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOSApp/Resources/SampleBooks/sample-en.epub")
        let epub = try Data(contentsOf: epubURL)
        let hash = DocumentIdentity().partialMD5(of: epub)

        let before = try await client.fetchBooks()
        let existing = before.first { $0.hash == hash }
        let uploaded = try await client.uploadBook(epub, book: ReadestUploadBook(
            hash: hash, metaHash: nil, title: "Folito integration test", author: "Folito CI"), existing: existing)
        var cleanedUp = false
        do {
            XCTAssertEqual(uploaded.hash, hash)
            let listed = try await client.fetchBooks().first { $0.hash == hash }
            XCTAssertEqual(listed?.isAvailable, true, "uploaded book should be listed with uploaded_at")
            // Reading status (#113). The test account's row may keep a status from an earlier run (a tombstone keeps
            // its columns), and the server stores a status only when its value changes, so the test first moves it
            // to a value it does not have, then to "finished".
            if let listed {
                let start = ReadStatusRules.millis(Date())
                let first: ReadStatus = listed.readStatusMark?.status == .unread ? .reading : .unread
                _ = try await client.setReadingStatus(ReadStatusMark(status: first, stamp: start), for: listed)
                let moved = try await client.fetchBook(hash: hash)
                XCTAssertEqual(moved?.readStatusMark?.status, first)
                XCTAssertEqual(Double(moved?.readStatusMark?.stamp ?? 0), Double(start), accuracy: 1)

                let stamp = start + 1000
                _ = try await client.setReadingStatus(ReadStatusMark(status: .finished, stamp: stamp), for: moved ?? listed)
                let finished = try await client.fetchBook(hash: hash)
                XCTAssertEqual(finished?.readStatusMark?.status, .finished)
                XCTAssertEqual(Double(finished?.readStatusMark?.stamp ?? 0), Double(stamp), accuracy: 1)
                XCTAssertEqual(finished?.isAvailable, true, "a status push keeps the row as it was")

                // An older "unread" from another device does not win: the client does not send it ...
                let older = ReadStatusMark(status: .unread, stamp: stamp - 60_000)
                let kept = try await client.setReadingStatus(older, for: finished ?? listed)
                XCTAssertEqual(kept.readStatusMark?.status, .finished, "the client keeps the newer remote status")
                // ... and the server rejects it too when it is pushed anyway (field-level last writer wins).
                if let finished { _ = try await client.pushBooks([finished.withReadStatus(older).wireRow()]) }
                let still = try await client.fetchBook(hash: hash)
                XCTAssertEqual(still?.readStatusMark?.status, .finished, "an older status must not win")
            }
            let url = try await client.bookDownloadURL(hash: hash)
            XCTAssertNotNil(url)
            if let url {
                let back = try await client.get(url)
                XCTAssertEqual(back, epub, "downloaded file must be byte-identical (same partial MD5)")
            }
            let usage = try await client.storageUsage()
            XCTAssertGreaterThan(usage.quota, 0)
            XCTAssertGreaterThanOrEqual(usage.usage, Int64(epub.count))
            try await client.deleteBook(listed ?? uploaded)
            cleanedUp = true
            let after = try await client.fetchBooks().first { $0.hash == hash }
            XCTAssertNotEqual(after?.isAvailable, true, "deleted book must not be listed")
            let gone = try await client.bookDownloadURL(hash: hash)
            XCTAssertNil(gone, "file must be removed from storage")
        } catch {
            if !cleanedUp { try? await client.deleteBook(uploaded) }
            await factory.signOut(credentials: store.load()!, session: .shared)
            throw error
        }
        await factory.signOut(credentials: store.load()!, session: .shared)
    }
}
