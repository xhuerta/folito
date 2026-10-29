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
}
