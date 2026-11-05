import XCTest
@testable import ReaderCore

/// One live request to Open Library (the Books API, by ISBN), run only when `OPENLIBRARY_LIVE_TEST=1`
/// (linux.yml, job openlibrary-smoke). Network problems skip the test instead of failing it: the point is to
/// notice if Open Library changes its answer format, not to depend on their uptime.
final class OpenLibraryLiveTests: XCTestCase {
    func testBooksAPIByISBN() async throws {
        guard ProcessInfo.processInfo.environment["OPENLIBRARY_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPENLIBRARY_LIVE_TEST=1 to run the live Open Library smoke test.")
        }
        let client = OpenLibraryClient(maxRetries: 1)
        let matches: [OnlineBookMatch]
        do {
            // Pride and Prejudice (Penguin Classics, 2003): a long-lived, well-catalogued edition.
            matches = try await client.lookup(OnlineLookupQuery(isbn: "9780141439518", title: "Pride and Prejudice",
                                                                authors: ["Jane Austen"]))
        } catch let error as OnlineMetadataError {
            throw XCTSkip("Open Library not reachable: \(error)")
        }
        let match = try XCTUnwrap(matches.first, "Open Library returned no match")
        XCTAssertTrue(match.title.localizedCaseInsensitiveContains("Pride and Prejudice"), match.title)
        XCTAssertTrue(match.authors.contains { $0.contains("Austen") }, "\(match.authors)")
        let requests = await client.requestLog.count
        XCTAssertEqual(requests, 1, "a single request")
    }
}
