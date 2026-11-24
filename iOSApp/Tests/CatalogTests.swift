import XCTest
import ReaderCore
@testable import Folito

/// The Catalogs list, its sign-ins and its errors (docs/OPDS.md). Feeds come from a stub transport (no network);
/// sign-ins go to an in-memory Keychain.
@MainActor
final class CatalogTests: XCTestCase {
    private final class StubTransport: OPDSTransport, @unchecked Sendable {
        let lock = NSLock()
        var answers: [URL: (Data, Int)] = [:]
        /// Hosts that answer 401 unless the request carries this `Authorization` header.
        var locked: [String: String] = [:]
        private(set) var asked: [URL] = []
        private(set) var authorizations: [String?] = []

        func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int, url: URL) {
            let answer: (Data, Int)? = lock.withLock {
                asked.append(url)
                authorizations.append(headers["Authorization"])
                if let host = url.host, let expected = locked[host], headers["Authorization"] != expected {
                    return (Data(), 401)
                }
                return answers[url]
            }
            guard let answer else { throw OPDSError.offline }
            return (answer.0, answer.1, url)
        }
    }

    private static func memoryKeychain() -> KeychainStore {
        var keychain = CatalogStore.makeKeychain()
        keychain.memory = MemoryKeychain()
        return keychain
    }

    private static let feed = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Home Library</title>
        <entry><title>New</title><link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/opds/new"/></entry>
        </feed>
        """.utf8)

    private func makeStore(_ transport: StubTransport, keychain: KeychainStore = memoryKeychain()) -> (CatalogStore, UserDefaults) {
        let suite = "CatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (CatalogStore(client: OPDSClient(transport: transport), defaults: defaults, keychain: keychain), defaults)
    }

    private let reader = OPDSCredentials(username: "reader", password: "correct horse")

    // MARK: Sign-in

    func testSignInIsCheckedAndKeptInTheKeychainOnly() async throws {
        let transport = StubTransport()
        let url = URL(string: "https://books.example.net/opds")!
        transport.answers[url] = (Self.feed, 200)
        transport.locked["books.example.net"] = reader.authorizationHeader
        let keychain = Self.memoryKeychain()
        let (store, defaults) = makeStore(transport, keychain: keychain)

        let missing = await store.add(address: url.absoluteString, name: "")
        XCTAssertEqual(missing, UserFacingError.catalogMessage(for: OPDSError.authenticationRequired), "401: ask for a sign-in")
        let wrong = await store.add(address: url.absoluteString, name: "", username: "reader", password: "nope")
        XCTAssertEqual(wrong, UserFacingError.catalogMessage(for: OPDSError.credentialsRejected))
        XCTAssertNil(keychain.get(account: "https://books.example.net:443"), "a refused sign-in is not saved")
        XCTAssertTrue(store.custom.isEmpty)

        let added = await store.add(address: url.absoluteString, name: "", username: " reader ", password: "correct horse")
        XCTAssertNil(added)
        XCTAssertEqual(store.custom.map(\.title), ["Home Library"])
        XCTAssertEqual(store.signIn(for: store.custom[0]), "reader")
        XCTAssertNotNil(keychain.get(account: "https://books.example.net:443"))
        // Nothing about the sign-in is in UserDefaults.
        let saved = try XCTUnwrap(defaults.data(forKey: CatalogStore.customKey))
        let text = String(decoding: saved, as: UTF8.self)
        XCTAssertFalse(text.contains("reader") || text.contains("correct horse"), text)
        for (_, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse("\(value)".contains("correct horse"))
        }

        // A new launch reads it back from the Keychain and sends it.
        let reloaded = CatalogStore(client: OPDSClient(transport: transport), defaults: defaults, keychain: keychain)
        XCTAssertEqual(reloaded.signIn(for: reloaded.custom[0]), "reader")
        let model = CatalogFeedModel(url: url, client: reloaded.client)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(transport.authorizations.last, reader.authorizationHeader)
    }

    func testNoSignInOverPlainHTTP() async {
        let transport = StubTransport()
        let url = URL(string: "http://192.168.1.20:8083/opds")!
        transport.answers[url] = (Data(), 401)
        let (store, _) = makeStore(transport)
        let refused = await store.add(address: url.absoluteString, name: "", username: "reader", password: "correct horse")
        XCTAssertEqual(refused, UserFacingError.catalogMessage(for: OPDSError.signInRequiresHTTPS))
        XCTAssertTrue(transport.asked.isEmpty, "the password is refused before anything is sent")

        let asked = await store.add(address: url.absoluteString, name: "")
        XCTAssertEqual(asked, UserFacingError.catalogMessage(for: OPDSError.signInRequiresHTTPS),
                       "an http catalog that wants a sign-in is told to use https")
        XCTAssertEqual(transport.authorizations, [nil])

        let model = CatalogFeedModel(url: url, client: store.client)
        await model.load()
        XCTAssertTrue(model.failedForSignIn)
        XCTAssertNil(store.signInCatalog(for: url), "no Sign In is offered for http")
    }

    func testFieldProblems() throws {
        XCTAssertNil(try CatalogStore.credentials(username: "", password: "").get(), "both empty: no sign-in")
        XCTAssertEqual(try CatalogStore.credentials(username: " reader ", password: " p ").get(),
                       OPDSCredentials(username: "reader", password: " p "), "the password is used as typed")
        if case .success = CatalogStore.credentials(username: "reader", password: "") { XCTFail("password missing") }
        if case .success = CatalogStore.credentials(username: "", password: "x") { XCTFail("user name missing") }
        if case .success = CatalogStore.credentials(username: "a:b", password: "x") { XCTFail("colon") }
    }

    func testEditKeepsReplacesAndRemovesTheSignIn() async throws {
        let transport = StubTransport()
        let url = URL(string: "https://books.example.net/opds")!
        let other = URL(string: "https://books.example.net/opds/second")!
        transport.answers[url] = (Self.feed, 200)
        transport.answers[other] = (Self.feed, 200)
        transport.locked["books.example.net"] = reader.authorizationHeader
        let keychain = Self.memoryKeychain()
        let (store, _) = makeStore(transport, keychain: keychain)
        let first = await store.add(address: url.absoluteString, name: "Home", username: "reader", password: "correct horse")
        XCTAssertNil(first)
        // A second catalog on the same server uses the server's sign-in.
        let second = await store.add(address: other.absoluteString, name: "Second")
        XCTAssertNil(second)
        XCTAssertEqual(store.signIn(for: store.custom[1]), "reader")
        let home = store.custom[0]

        XCTAssertEqual(store.signInChange(for: home, username: "reader", password: ""), .success(.keep),
                       "an empty password keeps the saved one")
        XCTAssertEqual(store.signInChange(for: home, username: "", password: ""), .success(.remove))
        if case .success = store.signInChange(for: home, username: "someone", password: "") { XCTFail("new user, no password") }

        let renamed = await store.update(home, name: "Renamed", username: "reader", password: "")
        XCTAssertNil(renamed)
        XCTAssertEqual(store.custom[0].title, "Renamed")
        let rejected = await store.update(store.custom[0], name: "Again", username: "reader", password: "wrong")
        XCTAssertEqual(rejected, UserFacingError.catalogMessage(for: OPDSError.credentialsRejected))
        XCTAssertEqual(store.custom[0].title, "Renamed", "nothing saved when the check fails")

        // Removing one catalog keeps the server's sign-in for the other; removing the last deletes it.
        store.remove(store.custom[0])
        XCTAssertNotNil(keychain.get(account: "https://books.example.net:443"))
        store.remove(store.custom[0])
        XCTAssertNil(keychain.get(account: "https://books.example.net:443"), "the Keychain item goes with the last catalog")
        XCTAssertNil(store.client.vault.credentials(forRequestTo: url))
    }

    func testRemoveSignIn() async {
        let transport = StubTransport()
        let url = URL(string: "https://books.example.net/opds")!
        transport.answers[url] = (Self.feed, 200)
        let keychain = Self.memoryKeychain()
        let (store, _) = makeStore(transport, keychain: keychain)
        let added = await store.add(address: url.absoluteString, name: "", username: "reader", password: "correct horse")
        XCTAssertNil(added)
        store.removeSignIn(for: store.custom[0])
        XCTAssertNil(store.signIn(for: store.custom[0]))
        XCTAssertNil(keychain.get(account: "https://books.example.net:443"))
        XCTAssertEqual(store.custom.count, 1, "the catalog stays")
        XCTAssertEqual(store.signInCatalog(for: URL(string: "https://books.example.net/opds/new")!)?.id, store.custom[0].id)
        XCTAssertNil(store.signInCatalog(for: OPDSCatalog.standardEbooks.url), "no sign-in for presets")
    }

    /// The real transport over a mocked `URLProtocol`: a redirect to another host does not carry the password.
    func testRedirectToAnotherHostDropsTheSignIn() async throws {
        RedirectingURLProtocol.reset()
        let vault = OPDSCredentialVault()
        let start = URL(string: "https://books.example.net/opds")!
        vault.set(reader, for: try XCTUnwrap(OPDSOrigin(start)))
        let client = OPDSClient(transport: URLSessionOPDSTransport(protocolClasses: [RedirectingURLProtocol.self]), vault: vault)
        _ = try await client.feed(at: start)
        let seen = RedirectingURLProtocol.seen
        XCTAssertEqual(seen.map(\.url.host), ["books.example.net", "books.example.net", "mirror.example.org"])
        XCTAssertEqual(seen.map(\.authorization), [reader.authorizationHeader, reader.authorizationHeader, nil],
                       "kept on its own server, dropped for another")
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

/// `https://books.example.net/opds` redirects to `/opds/` on the same server, which redirects to another host that
/// answers with a feed. The redirected requests keep the original headers (as the system loader does), so only
/// the transport's redirect rule can remove the `Authorization` header.
final class RedirectingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let authorization: String? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [Seen] = []
    static var seen: [Seen] { lock.withLock { _seen } }
    static func reset() { lock.withLock { _seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        Self.lock.withLock { Self._seen.append(Seen(url: url, authorization: authorization)) }
        let target: URL?
        switch url.absoluteString {
        case "https://books.example.net/opds": target = URL(string: "https://books.example.net/opds/")
        case "https://books.example.net/opds/": target = URL(string: "https://mirror.example.org/opds")
        default: target = nil
        }
        if let target {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        let body = Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Mirror</title></feed>".utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/atom+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
