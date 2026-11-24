import XCTest
import ReaderCore
@testable import Folito

/// The Catalogs list and its errors (docs/OPDS.md). Feeds come from a stub transport: no network.
@MainActor
final class CatalogTests: XCTestCase {
    private final class StubTransport: OPDSTransport, @unchecked Sendable {
        let lock = NSLock()
        var answers: [URL: (Data, Int)] = [:]
        private(set) var asked: [URL] = []

        func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int, url: URL) {
            let answer: (Data, Int)? = lock.withLock {
                asked.append(url)
                return answers[url]
            }
            guard let answer else { throw OPDSError.offline }
            return (answer.0, answer.1, url)
        }
    }

    private static let feed = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Home Library</title>
        <entry><title>New</title><link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/opds/new"/></entry>
        </feed>
        """.utf8)

    private func makeStore(_ transport: StubTransport) -> (CatalogStore, UserDefaults) {
        let suite = "CatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (CatalogStore(client: OPDSClient(transport: transport), defaults: defaults), defaults)
    }

    func testPresetsAreListedButNotContacted() {
        let transport = StubTransport()
        let (store, _) = makeStore(transport)
        XCTAssertEqual(store.all.map(\.title), ["Standard Ebooks", "Project Gutenberg"])
        XCTAssertTrue(transport.asked.isEmpty)
    }

    func testAddChecksTheAddressAndPersists() async {
        let transport = StubTransport()
        let url = URL(string: "https://books.example.net/opds")!
        transport.answers[url] = (Self.feed, 200)
        let (store, defaults) = makeStore(transport)

        let problem = await store.add(address: "books.example.net/opds", name: " ")
        XCTAssertNil(problem)
        XCTAssertEqual(store.custom.map(\.title), ["Home Library"], "named after the feed when no name is given")
        XCTAssertEqual(transport.asked, [url])

        let reloaded = CatalogStore(client: OPDSClient(transport: transport), defaults: defaults)
        XCTAssertEqual(reloaded.custom.map(\.url), [url])

        let duplicate = await store.add(address: "https://books.example.net/opds", name: "")
        XCTAssertNotNil(duplicate)
        store.remove(store.custom[0])
        XCTAssertTrue(store.custom.isEmpty)
    }

    func testAddRejectsBadAddressesAndFailures() async {
        let transport = StubTransport()
        let (store, _) = makeStore(transport)
        let bad = await store.add(address: "ftp://example.com", name: "")
        XCTAssertNotNil(bad)
        XCTAssertTrue(transport.asked.isEmpty, "an invalid address is not requested")

        let locked = URL(string: "https://locked.example.com/opds")!
        transport.answers[locked] = (Data(), 401)
        let message = await store.add(address: locked.absoluteString, name: "Locked")
        XCTAssertEqual(message, UserFacingError.catalogMessage(for: OPDSError.authenticationRequired))
        XCTAssertTrue(store.custom.isEmpty)
    }

    func testFeedModelPaginates() async {
        let transport = StubTransport()
        let first = URL(string: "https://example.com/opds/new")!
        let second = URL(string: "https://example.com/opds/new?page=2")!
        transport.answers[first] = (Data("""
            <feed xmlns="http://www.w3.org/2005/Atom"><title>New</title><link rel="next" href="?page=2"/>
            <entry><id>a</id><title>A</title><link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="a.epub"/></entry>
            </feed>
            """.utf8), 200)
        transport.answers[second] = (Data("""
            <feed xmlns="http://www.w3.org/2005/Atom"><title>New</title><link rel="next" href="?page=2"/>
            <entry><id>a</id><title>A</title></entry><entry><id>b</id><title>B</title></entry>
            </feed>
            """.utf8), 200)
        let model = CatalogFeedModel(url: first, client: OPDSClient(transport: transport))
        await model.loadIfNeeded()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.entries.map(\.id), ["a"])
        XCTAssertEqual(model.nextURL, second)
        await model.loadMore()
        XCTAssertEqual(model.entries.map(\.id), ["a", "b"])
        XCTAssertNil(model.nextURL, "a page that points to itself ends the list")
    }

    func testErrorMessages() {
        XCTAssertEqual(UserFacingError.catalogFailed(OPDSError.notAFeed).title, "Couldn’t Open Catalog")
        XCTAssertTrue(UserFacingError.catalogFailed(OPDSError.authenticationRequired).message.contains("sign-in"))
        XCTAssertTrue(UserFacingError.catalogFailed(OPDSError.server(status: 503)).message.contains("503"))
        let download = UserFacingError.catalogDownloadFailed(title: "Emma", error: OPDSError.notAnEPUB)
        XCTAssertEqual(download.title, "Couldn’t Download Book")
        XCTAssertTrue(download.message.contains("Emma"))
    }

    func testDownloadFileName() {
        XCTAssertEqual(CatalogStore.fileName(for: OPDSEntry(id: "1", title: "Pride and Prejudice")), "Pride and Prejudice.epub")
        XCTAssertEqual(CatalogStore.fileName(for: OPDSEntry(id: "2", title: "AC/DC: A History?")), "AC DC  A History.epub")
        XCTAssertEqual(CatalogStore.fileName(for: OPDSEntry(id: "3", title: "///")), "Book.epub")
    }
}
