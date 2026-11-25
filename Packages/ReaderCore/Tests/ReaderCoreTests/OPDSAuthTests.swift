import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReaderCore

/// OPDS part 2 (docs/OPDS.md, "Sign-in"): HTTP Basic credentials for self-hosted catalogs, where they may be sent,
/// and feeds in the shape Calibre's content server, Komga and Kavita produce. No test here touches the network:
/// the client tests use `MockOPDSTransport`, the transport tests a mocked `URLProtocol`.
///
/// Fixtures (Tests/Fixtures/OPDS): `calibre-*.xml`, `komga-*.xml` and `kavita-series.xml` are written by hand in the
/// shape those servers produce (element names, link types and relative paths as in their OPDS code), like the
/// Calibre-Web fixtures of part 1.
final class OPDSAuthTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/OPDS")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    private let alice = OPDSCredentials(username: "alice", password: "s3cret:pässword")
    private let server = URL(string: "https://books.example.net:8083/opds")!

    // MARK: Credentials

    func testBasicHeaderAndRedaction() {
        XCTAssertEqual(OPDSCredentials(username: "Aladdin", password: "open sesame").authorizationHeader,
                       "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==", "RFC 7617 example")
        // UTF-8, and a colon in the password is allowed.
        XCTAssertEqual(alice.authorizationHeader, "Basic " + Data("alice:s3cret:pässword".utf8).base64EncodedString())
        XCTAssertFalse("\(alice)".contains("s3cret"), "the password never appears in a description")
        XCTAssertFalse(String(reflecting: alice).contains("s3cret"))
        XCTAssertTrue("\(alice)".contains("alice"))
    }

    func testCredentialProblems() {
        XCTAssertNil(alice.problem)
        XCTAssertEqual(OPDSCredentials(username: "", password: "x").problem, .missingUsername)
        XCTAssertEqual(OPDSCredentials(username: "a", password: "").problem, .missingPassword)
        XCTAssertEqual(OPDSCredentials(username: "a:b", password: "x").problem, .colonInUsername)
        XCTAssertEqual(OPDSCredentials(username: "a", password: "x\ny").problem, .controlCharacters)
    }

    // MARK: Origins and policy

    func testOrigins() throws {
        let origin = try XCTUnwrap(OPDSOrigin(server))
        XCTAssertEqual(origin.description, "https://books.example.net:8083")
        XCTAssertEqual(OPDSOrigin(URL(string: "HTTPS://Books.Example.NET:8083/other")!), origin, "case-insensitive")
        XCTAssertEqual(OPDSOrigin(URL(string: "https://example.com/x")!)?.port, 443)
        XCTAssertEqual(OPDSOrigin(URL(string: "https://example.com:443/x")!), OPDSOrigin(URL(string: "https://example.com/y")!))
        XCTAssertEqual(OPDSOrigin(URL(string: "http://example.com/x")!)?.port, 80)
        XCTAssertNil(OPDSOrigin(URL(string: "ftp://example.com/x")!))
        XCTAssertNil(OPDSOrigin(URL(fileURLWithPath: "/etc/passwd")))
    }

    func testPolicy() throws {
        let origin = try XCTUnwrap(OPDSOrigin(server))
        XCTAssertTrue(OPDSSignInPolicy.canSignIn(to: server))
        XCTAssertFalse(OPDSSignInPolicy.canSignIn(to: URL(string: "http://192.168.1.20:8080/opds")!),
                       "no sign-in over plain http")
        XCTAssertTrue(OPDSSignInPolicy.mayAuthorize(URL(string: "https://books.example.net:8083/opds/cover/1")!, for: origin))
        XCTAssertFalse(OPDSSignInPolicy.mayAuthorize(URL(string: "https://books.example.net/opds")!, for: origin), "other port")
        XCTAssertFalse(OPDSSignInPolicy.mayAuthorize(URL(string: "https://cdn.example.net:8083/c.jpg")!, for: origin), "other host")
        XCTAssertFalse(OPDSSignInPolicy.mayAuthorize(URL(string: "https://example.net:8083/c.jpg")!, for: origin), "parent domain")
        XCTAssertFalse(OPDSSignInPolicy.mayAuthorize(URL(string: "http://books.example.net:8083/opds")!, for: origin), "http")
        let http = try XCTUnwrap(OPDSOrigin(URL(string: "http://books.local/opds")!))
        XCTAssertFalse(OPDSSignInPolicy.mayAuthorize(URL(string: "http://books.local/opds")!, for: http),
                       "an http origin never authorizes, even itself")
    }

    func testRedirectStripsAuthorizationOffOrigin() {
        func request(_ url: String) -> URLRequest {
            var r = URLRequest(url: URL(string: url)!)
            r.setValue(alice.authorizationHeader, forHTTPHeaderField: "Authorization")
            r.setValue("Folito", forHTTPHeaderField: "User-Agent")
            return r
        }
        let same = OPDSSignInPolicy.redirected(request("https://books.example.net:8083/opds/"), from: server)
        XCTAssertEqual(same.value(forHTTPHeaderField: "Authorization"), alice.authorizationHeader)
        for target in ["https://cdn.example.org/book.epub", "http://books.example.net:8083/opds",
                       "https://books.example.net/opds", "https://evil.example.net:8083/opds"] {
            let moved = OPDSSignInPolicy.redirected(request(target), from: server)
            XCTAssertNil(moved.value(forHTTPHeaderField: "Authorization"), target)
            XCTAssertEqual(moved.value(forHTTPHeaderField: "User-Agent"), "Folito", "other headers stay")
        }
        XCTAssertNil(OPDSSignInPolicy.redirected(request("https://books.example.net:8083/x"), from: nil)
            .value(forHTTPHeaderField: "Authorization"), "unknown original: stripped")
    }

    func testVaultKeepsHTTPSOriginsOnly() throws {
        let vault = OPDSCredentialVault()
        vault.set(alice, for: try XCTUnwrap(OPDSOrigin(URL(string: "http://books.local/opds")!)))
        XCTAssertNil(vault.credentials(forRequestTo: URL(string: "http://books.local/opds")!))
        vault.set(alice, for: try XCTUnwrap(OPDSOrigin(server)))
        XCTAssertEqual(vault.credentials(forRequestTo: URL(string: "https://books.example.net:8083/get/1")!), alice)
        XCTAssertNil(vault.credentials(forRequestTo: URL(string: "https://books.example.net/get/1")!))
        vault.set(nil, for: try XCTUnwrap(OPDSOrigin(server)))
        XCTAssertNil(vault.credentials(forRequestTo: server))
    }

    // MARK: Client

    func testSavedSignInGoesOnlyToItsOwnServer() async throws {
        let transport = MockOPDSTransport()
        let vault = OPDSCredentialVault()
        vault.set(alice, for: try XCTUnwrap(OPDSOrigin(server)))
        let client = OPDSClient(transport: transport, vault: vault)
        transport.responses[server] = (try fixture("calibreweb-root.xml"), 200, server)
        let ownCover = URL(string: "https://books.example.net:8083/opds/cover/12")!
        let foreignCover = URL(string: "https://covers.example.org/12.jpg")!
        transport.responses[ownCover] = (Data([0xFF, 0xD8]), 200, ownCover)
        transport.responses[foreignCover] = (Data([0xFF, 0xD8]), 200, foreignCover)
        let epub = OPDSLink(url: URL(string: "https://books.example.net:8083/opds/download/12/epub/")!,
                            rel: "http://opds-spec.org/acquisition", type: "application/epub+zip")
        transport.responses[epub.url] = (Data([0x50, 0x4B, 0x03, 0x04, 0]), 200, epub.url)

        _ = try await client.feed(at: server)
        _ = try await client.image(at: ownCover)
        _ = try await client.image(at: foreignCover)
        _ = try await client.download(epub)

        let sent = transport.requests
        XCTAssertEqual(sent.map { $0.headers["Authorization"] },
                       [alice.authorizationHeader, alice.authorizationHeader, nil, alice.authorizationHeader])
        XCTAssertEqual(Set(sent[2].headers.keys), ["User-Agent", "Accept"], "nothing else to another host")
        let log = await client.requestLog
        XCTAssertFalse(log.map(\.absoluteString).joined().contains("alice"), "the log holds addresses only")
    }

    func testAuthenticationErrors() async throws {
        let transport = MockOPDSTransport()
        let vault = OPDSCredentialVault()
        let client = OPDSClient(transport: transport, vault: vault)
        transport.responses[server] = (Data("Unauthorized".utf8), 401, server)
        do { _ = try await client.feed(at: server); XCTFail() } catch {
            XCTAssertEqual(error as? OPDSError, .authenticationRequired, "no sign-in sent: ask for one")
        }
        vault.set(alice, for: try XCTUnwrap(OPDSOrigin(server)))
        do { _ = try await client.feed(at: server); XCTFail() } catch {
            XCTAssertEqual(error as? OPDSError, .credentialsRejected, "a sign-in was sent: it is wrong")
            XCTAssertTrue((error as? OPDSError)?.isAuthentication == true)
        }
        transport.responses[server] = (Data(), 403, server)
        do { _ = try await client.feed(at: server); XCTFail() } catch {
            XCTAssertEqual(error as? OPDSError, .accessDenied)
            XCTAssertFalse((error as? OPDSError)?.isAuthentication == true)
        }
    }

    func testCheckFeedUsesExactlyTheGivenSignIn() async throws {
        let transport = MockOPDSTransport()
        let vault = OPDSCredentialVault()
        vault.set(OPDSCredentials(username: "old", password: "old"), for: try XCTUnwrap(OPDSOrigin(server)))
        let client = OPDSClient(transport: transport, vault: vault)
        transport.responses[server] = (try fixture("calibreweb-root.xml"), 200, server)

        _ = try await client.checkFeed(at: server, credentials: alice)
        XCTAssertEqual(transport.requests.last?.headers["Authorization"], alice.authorizationHeader)
        _ = try await client.checkFeed(at: server, credentials: nil)
        XCTAssertNil(transport.requests.last?.headers["Authorization"], "nil means none, not the saved one")

        let http = URL(string: "http://192.168.1.20:8080/opds")!
        transport.responses[http] = (try fixture("calibreweb-root.xml"), 200, http)
        let before = transport.requests.count
        do { _ = try await client.checkFeed(at: http, credentials: alice); XCTFail() } catch {
            XCTAssertEqual(error as? OPDSError, .signInRequiresHTTPS)
        }
        XCTAssertEqual(transport.requests.count, before, "refused before anything is sent")
        _ = try await client.checkFeed(at: http, credentials: nil)
        XCTAssertNil(transport.requests.last?.headers["Authorization"], "an http catalog without sign-in still works")
    }

    // MARK: Server shapes

    func testCalibreContentServer() throws {
        let root = try OPDSParser.parse(fixture("calibre-root.xml"), url: URL(string: "https://nas.example.net:8080/opds")!)
        XCTAssertEqual(root.title, "calibre Library")
        XCTAssertEqual(root.entries.map(\.title), ["By Title", "By Newest", "By Author"])
        XCTAssertEqual(root.entries[1].navigationURL?.absoluteString,
                       "https://nas.example.net:8080/opds/navcatalog/4f6e6577657374?library_id=Calibre_Library",
                       "a link without rel leads to the feed")

        let newest = try OPDSParser.parse(fixture("calibre-newest.xml"),
                                          url: URL(string: "https://nas.example.net:8080/opds/navcatalog/4f6e6577657374?library_id=Calibre_Library")!)
        XCTAssertEqual(newest.nextURL?.absoluteString,
                       "https://nas.example.net:8080/opds/navcatalog/4f6e6577657374?library_id=Calibre_Library&offset=25")
        let emma = newest.entries[0]
        XCTAssertEqual(emma.kind, .book)
        XCTAssertEqual(emma.authors, ["Jane Austen"])
        XCTAssertEqual(emma.epubLink?.url.absoluteString, "https://nas.example.net:8080/get/epub/3/Calibre_Library")
        XCTAssertEqual(emma.epubLink?.length, 512_345)
        XCTAssertEqual(emma.imageURL?.absoluteString, "https://nas.example.net:8080/get/cover/3/Calibre_Library")
        XCTAssertEqual(emma.thumbnailURL?.absoluteString, "https://nas.example.net:8080/get/thumb/3/Calibre_Library")
        XCTAssertTrue(emma.summary?.contains("Emma Woodhouse") == true, "XHTML content becomes plain text")
        XCTAssertNil(newest.entries[1].epubLink, "PDF only")
    }

    func testKomga() throws {
        let base = URL(string: "https://komga.example.net/opds/v1.2/catalog")!
        let root = try OPDSParser.parse(fixture("komga-root.xml"), url: base)
        XCTAssertEqual(root.title, "Komga OPDS catalog")
        XCTAssertEqual(root.entries.map(\.navigationURL?.absoluteString), [
            "https://komga.example.net/opds/v1.2/books/ondeck",
            "https://komga.example.net/opds/v1.2/books/latest",
            "https://komga.example.net/opds/v1.2/libraries",
        ])
        let latest = try OPDSParser.parse(fixture("komga-latest.xml"),
                                          url: URL(string: "https://komga.example.net/opds/v1.2/books/latest")!)
        XCTAssertEqual(latest.nextURL?.absoluteString, "https://komga.example.net/opds/v1.2/books/latest?page=1")
        XCTAssertEqual(latest.entries[0].epubLink?.url.absoluteString,
                       "https://komga.example.net/opds/v1.2/books/0J5Q2TB1A3F9K/file/Northanger%20Abbey.epub")
        XCTAssertEqual(latest.entries[0].thumbnailURL?.absoluteString,
                       "https://komga.example.net/opds/v1.2/books/0J5Q2TB1A3F9K/thumbnail/small")
        XCTAssertEqual(latest.entries[1].kind, .book)
        XCTAssertNil(latest.entries[1].epubLink, "a CBZ comic and its page stream are not EPUB")
    }

    func testKavita() throws {
        let feed = try OPDSParser.parse(fixture("kavita-series.xml"),
                                        url: URL(string: "https://kavita.example.net/api/opds/00000000-0000-0000-0000-00000000test/series/3")!)
        let book = try XCTUnwrap(feed.entries.first)
        XCTAssertEqual(book.authors, ["Jane Austen"])
        XCTAssertEqual(book.language, "en")
        XCTAssertEqual(book.epubLink?.rel, "http://opds-spec.org/acquisition/open-access")
        XCTAssertEqual(book.epubLink?.url.absoluteString,
                       "https://kavita.example.net/api/opds/00000000-0000-0000-0000-00000000test/series/3/volume/4/chapter/5/download/Persuasion.epub")
    }

    // MARK: URLSession transport (mocked URLProtocol)

    func testTransportSendsTheHeaderAndKeepsNoCredentials() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.answer = { request in
            let authorized = request.value(forHTTPHeaderField: "Authorization") != nil
            return (authorized ? 200 : 401, authorized ? Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Home</title></feed>".utf8) : Data())
        }
        let vault = OPDSCredentialVault()
        let client = OPDSClient(transport: URLSessionOPDSTransport(protocolClasses: [StubURLProtocol.self]), vault: vault)
        do { _ = try await client.feed(at: server); XCTFail() } catch {
            XCTAssertEqual(error as? OPDSError, .authenticationRequired)
        }
        vault.set(alice, for: try XCTUnwrap(OPDSOrigin(server)))
        let feed = try await client.feed(at: server)
        XCTAssertEqual(feed.title, "Home")
        vault.set(nil, for: try XCTUnwrap(OPDSOrigin(server)))
        do { _ = try await client.feed(at: server); XCTFail("nothing was remembered by the session") } catch {
            XCTAssertEqual(error as? OPDSError, .authenticationRequired)
        }
        XCTAssertEqual(StubURLProtocol.seen.map(\.authorization), [nil, alice.authorizationHeader, nil])
    }
}

/// Answers every request through `answer` and records the `Authorization` header it saw.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let authorization: String? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _answer: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var _seen: [Seen] = []

    static var answer: (@Sendable (URLRequest) -> (Int, Data))? {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    static var seen: [Seen] { lock.withLock { _seen } }
    static func reset() { lock.withLock { _seen = []; _answer = nil } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self._seen.append(Seen(url: url, authorization: request.value(forHTTPHeaderField: "Authorization"))) }
        let (status, body) = Self.answer?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/atom+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
