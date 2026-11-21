import XCTest
@testable import ReaderCore

/// OPDS 1.2 catalogs (docs/OPDS.md): parsing of recorded and hand-written feeds, the choice of the EPUB download,
/// pagination, catalog addresses and the client's error handling. The transport is mocked: no test here touches
/// the network.
///
/// Fixtures (Tests/Fixtures/OPDS): `standardebooks-new-releases.xml` is Standard Ebooks' new releases feed as
/// served on 2026-11-21, cut to three entries. Project Gutenberg was down for maintenance and Calibre-Web is
/// self-hosted, so `gutenberg-*.xml` and `calibreweb-*.xml` are written by hand in the shape those servers produce;
/// `edge-cases.xml` holds the acquisition cases of the OPDS 1.2 specification that must be skipped.
final class OPDSTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/OPDS")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    private func parse(_ name: String, url: String) throws -> OPDSFeed {
        try OPDSParser.parse(fixture(name), url: URL(string: url)!)
    }

    // MARK: Standard Ebooks (plain Atom with enclosures)

    func testStandardEbooksNewReleases() throws {
        let feed = try parse("standardebooks-new-releases.xml", url: "https://standardebooks.org/feeds/atom/new-releases")
        XCTAssertEqual(feed.title, "Standard Ebooks - Newest Ebooks")
        XCTAssertEqual(feed.subtitle, "The 15 latest Standard Ebooks, most-recently-released first.")
        XCTAssertEqual(feed.kind, .acquisition)
        XCTAssertNil(feed.nextURL)
        XCTAssertEqual(feed.entries.map(\.title), ["Confessions of Zeno", "The Duke of York’s Steps", "A Fighting Man of Mars"])

        let zeno = feed.entries[0]
        XCTAssertEqual(zeno.kind, .book)
        XCTAssertEqual(zeno.id, "https://standardebooks.org/ebooks/italo-svevo/confessions-of-zeno/beryl-de-zoete")
        XCTAssertEqual(zeno.authors, ["Italo Svevo"])
        XCTAssertEqual(zeno.summary, "To quit smoking, a man writes his memoirs.")
        XCTAssertEqual(zeno.year, 2026, "no dcterms:issued: the year of <published>")
        XCTAssertTrue(zeno.categories.contains("Fiction"))
        XCTAssertEqual(zeno.thumbnailURL?.absoluteString,
                       "https://standardebooks.org/ebooks/italo-svevo/confessions-of-zeno/beryl-de-zoete/downloads/cover-thumbnail.jpg")
        XCTAssertEqual(zeno.imageURL, zeno.thumbnailURL, "only a thumbnail: used for both")
        // Five enclosures (two EPUBs, kepub, azw3, XHTML); the recommended compatible EPUB is the one taken.
        XCTAssertEqual(zeno.acquisitions.count, 5)
        let epub = try XCTUnwrap(zeno.epubLink)
        XCTAssertEqual(epub.title, "Recommended compatible epub")
        XCTAssertEqual(epub.length, 875_562)
        XCTAssertEqual(epub.url.absoluteString,
                       "https://standardebooks.org/ebooks/italo-svevo/confessions-of-zeno/beryl-de-zoete/downloads/italo-svevo_confessions-of-zeno_beryl-de-zoete.epub?source=feed")
        XCTAssertNil(zeno.navigationURL, "the alternate link is a web page, not a feed")
    }

    // MARK: Project Gutenberg

    func testGutenbergRootIsNavigation() throws {
        let feed = try parse("gutenberg-root.xml", url: "https://www.gutenberg.org/ebooks.opds/")
        XCTAssertEqual(feed.title, "Project Gutenberg")
        XCTAssertEqual(feed.kind, .navigation)
        XCTAssertEqual(feed.startURL?.absoluteString, "https://www.gutenberg.org/ebooks.opds/")
        XCTAssertEqual(feed.iconURL?.absoluteString, "https://www.gutenberg.org/gutenberg/favicon.png")
        XCTAssertEqual(feed.entries.map(\.title), ["Popular", "Latest", "Random"])
        let popular = feed.entries[0]
        XCTAssertEqual(popular.kind, .navigation)
        XCTAssertEqual(popular.summary, "Our most popular books.")
        XCTAssertEqual(popular.navigationURL?.absoluteString,
                       "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads")
        XCTAssertEqual(popular.thumbnailURL?.absoluteString, "https://www.gutenberg.org/gutenberg/popular.png")
    }

    func testGutenbergPopularPaginates() throws {
        let feed = try parse("gutenberg-popular.xml", url: "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads")
        XCTAssertEqual(feed.nextURL?.absoluteString,
                       "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads&start_index=26")
        XCTAssertEqual(feed.entries.count, 3)
        // Search results lead to each book's own feed; the content is the author.
        let pride = feed.entries[1]
        XCTAssertEqual(pride.kind, .navigation)
        XCTAssertEqual(pride.summary, "Jane Austen")
        XCTAssertEqual(pride.navigationURL?.absoluteString, "https://www.gutenberg.org/ebooks/1342.opds")
        XCTAssertEqual(pride.listImageURL?.absoluteString,
                       "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.small.jpg")

        let page2 = try parse("gutenberg-popular-page2.xml",
                              url: "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads&start_index=26")
        XCTAssertNil(page2.nextURL, "the last page has no next link")
        // Pages may overlap; the browser keeps the first copy.
        let merged = OPDSPages.append(page2.entries, to: feed.entries)
        XCTAssertEqual(merged.map(\.title), ["Frankenstein; Or, The Modern Prometheus", "Pride and Prejudice",
                                             "Moby Dick; Or, The Whale", "A Tale of Two Cities"])
    }

    func testGutenbergBookFeed() throws {
        let feed = try parse("gutenberg-book-1342.xml", url: "https://www.gutenberg.org/ebooks/1342.opds")
        XCTAssertEqual(feed.kind, .acquisition)
        XCTAssertEqual(feed.entries.count, 3)
        let book = feed.entries[0]
        XCTAssertEqual(book.kind, .book)
        XCTAssertEqual(book.id, "urn:gutenberg:1342:3")
        XCTAssertEqual(book.authors, ["Austen, Jane"])
        XCTAssertEqual(book.language, "en")
        XCTAssertEqual(book.year, 1998)
        XCTAssertEqual(book.categories, ["Courtship -- Fiction", "Young women -- Fiction", "England -- Fiction"])
        // XHTML content becomes plain paragraphs, entities decoded.
        XCTAssertEqual(book.summary, """
            "Pride and Prejudice" by Jane Austen is a classic novel written in the early 19th century.

            The story follows Elizabeth Bennet & her sisters as they navigate love, class and family.
            """)
        XCTAssertEqual(book.imageURL?.absoluteString, "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg")
        XCTAssertEqual(book.thumbnailURL?.absoluteString, "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.small.jpg")
        XCTAssertEqual(book.acquisitions.count, 6)
        XCTAssertEqual(book.epubLink?.url.absoluteString, "https://www.gutenberg.org/ebooks/1342.epub3.images")
        // "By Jane Austen" and "Readers also downloaded…" are related feeds.
        XCTAssertEqual(feed.entries[1].kind, .navigation)
        XCTAssertEqual(feed.entries[1].navigationURL?.absoluteString, "https://www.gutenberg.org/ebooks/author/68.opds")
    }

    // MARK: Calibre-Web

    func testCalibreWebRootResolvesRelativeLinks() throws {
        let feed = try parse("calibreweb-root.xml", url: "https://books.example.net:8083/opds")
        XCTAssertEqual(feed.kind, .navigation)
        XCTAssertEqual(feed.iconURL?.absoluteString, "https://books.example.net:8083/static/favicon.ico")
        XCTAssertEqual(feed.entries.map(\.navigationURL?.absoluteString), [
            "https://books.example.net:8083/opds/books",
            "https://books.example.net:8083/opds/new",
            "https://books.example.net:8083/opds/author",
        ])
        XCTAssertEqual(feed.entries[1].summary, "The latest Books")
    }

    func testCalibreWebAcquisitionFeed() throws {
        let feed = try parse("calibreweb-new.xml", url: "https://books.example.net:8083/opds/new")
        XCTAssertEqual(feed.kind, .acquisition)
        XCTAssertEqual(feed.nextURL?.absoluteString, "https://books.example.net:8083/opds/new?offset=30")

        let timeMachine = feed.entries[0]
        XCTAssertEqual(timeMachine.authors, ["H. G. Wells"])
        XCTAssertEqual(timeMachine.publisher, "Standard Ebooks")
        XCTAssertEqual(timeMachine.year, 1895)
        XCTAssertEqual(timeMachine.categories, ["Science Fiction"])
        XCTAssertEqual(timeMachine.summary,
                       "A Victorian inventor travels to the year 802,701 and finds humanity split in two.",
                       "HTML in a text summary is stripped")
        XCTAssertEqual(timeMachine.epubLink?.url.absoluteString, "https://books.example.net:8083/opds/download/12/epub/")
        XCTAssertEqual(timeMachine.imageURL?.absoluteString, "https://books.example.net:8083/opds/cover/12")

        let war = feed.entries[1]
        XCTAssertEqual(war.authors, ["H. G. Wells", "Warwick Goble"])
        XCTAssertEqual(war.epubLink?.url.absoluteString, "https://books.example.net:8083/opds/download/11/epub/",
                       "the kepub listed first is skipped")

        let atlas = feed.entries[2]
        XCTAssertEqual(atlas.kind, .book)
        XCTAssertNil(atlas.epubLink, "PDF only")
    }

    // MARK: Acquisition rules

    func testDRMAndPaidLinksAreSkipped() throws {
        let feed = try parse("edge-cases.xml", url: "https://store.example.com/catalog/new.xml")
        XCTAssertEqual(feed.title, "Edge & Cases")
        XCTAssertNil(feed.nextURL, "a javascript: link is dropped")
        let byTitle = Dictionary(uniqueKeysWithValues: feed.entries.map { ($0.title, $0) })
        XCTAssertNil(byTitle["Adobe DRM"]?.epubLink, "ACSM with an indirect EPUB")
        XCTAssertEqual(byTitle["Adobe DRM"]?.acquisitions.first?.indirectTypes, ["application/epub+zip"])
        XCTAssertNil(byTitle["LCP"]?.epubLink)
        XCTAssertNil(byTitle["Bought or Borrowed"]?.epubLink, "buy, borrow and sample are not downloads")
        XCTAssertEqual(byTitle["Bought or Borrowed"]?.kind, .book)

        let open = try XCTUnwrap(byTitle["Open Access"])
        XCTAssertEqual(open.summary, "An open book.")
        // The sample comes first but is skipped; the file: link is dropped; parameters on the type are ignored.
        XCTAssertEqual(open.epubLink?.url.absoluteString, "https://store.example.com/books/4.epub")
        XCTAssertEqual(open.epubLink?.length, 1234)
        XCTAssertEqual(open.acquisitions.count, 2)
        XCTAssertEqual(open.imageURL?.absoluteString, "https://store.example.com/catalog/covers/4.png",
                       "the pre-1.1 cover rel")

        let entryDocument = try XCTUnwrap(feed.entries.last)
        XCTAssertEqual(entryDocument.title, "Untitled whitespace")
        XCTAssertNil(entryDocument.navigationURL, "a link to an entry document is not a feed")
    }

    func testPreferredEPUBPolicy() {
        let base = URL(string: "https://example.com/")!
        func link(_ rel: String?, _ type: String?, indirect: [String] = []) -> OPDSLink {
            OPDSLink(url: base.appendingPathComponent(UUID().uuidString), rel: rel, type: type, indirectTypes: indirect)
        }
        XCTAssertTrue(OPDSAcquisitionPolicy.isDirectEPUB(link("http://opds-spec.org/acquisition", "application/epub+zip")))
        XCTAssertTrue(OPDSAcquisitionPolicy.isDirectEPUB(link("http://opds-spec.org/acquisition/open-access", "Application/EPUB+zip ; x=y")))
        XCTAssertTrue(OPDSAcquisitionPolicy.isDirectEPUB(link("enclosure", "application/epub+zip")))
        XCTAssertFalse(OPDSAcquisitionPolicy.isDirectEPUB(link(nil, "application/epub+zip")))
        XCTAssertFalse(OPDSAcquisitionPolicy.isDirectEPUB(link("alternate", "application/epub+zip")))
        XCTAssertFalse(OPDSAcquisitionPolicy.isDirectEPUB(link("http://opds-spec.org/acquisition/buy", "application/epub+zip")))
        XCTAssertFalse(OPDSAcquisitionPolicy.isDirectEPUB(link("http://opds-spec.org/acquisition/subscribe", "application/epub+zip")))
        XCTAssertFalse(OPDSAcquisitionPolicy.isDirectEPUB(link("http://opds-spec.org/acquisition", "application/kepub+zip")))
        XCTAssertFalse(OPDSAcquisitionPolicy.isDirectEPUB(link("http://opds-spec.org/acquisition", "application/pdf")))
        XCTAssertFalse(OPDSAcquisitionPolicy.isDirectEPUB(link("http://opds-spec.org/acquisition", nil)))
        XCTAssertFalse(OPDSAcquisitionPolicy.isDirectEPUB(link("http://opds-spec.org/acquisition", "application/epub+zip",
                                                               indirect: ["application/vnd.adobe.adept+xml"])))
    }

    // MARK: Robustness

    func testEntryDocumentAndRejections() throws {
        let entry = Data("""
            <entry xmlns="http://www.w3.org/2005/Atom"><title>Solo</title><id>urn:x:1</id>
            <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="solo.epub"/></entry>
            """.utf8)
        let feed = try OPDSParser.parse(entry, url: URL(string: "https://example.com/a/entry.xml")!)
        XCTAssertEqual(feed.entries.count, 1)
        XCTAssertEqual(feed.entries[0].epubLink?.url.absoluteString, "https://example.com/a/solo.epub")

        let html = Data("<!DOCTYPE html><html><head><title>Login</title></head><body><p>Sign in</p></body></html>".utf8)
        XCTAssertThrowsError(try OPDSParser.parse(html, url: URL(string: "https://example.com/")!)) {
            XCTAssertEqual($0 as? OPDSError, .notAFeed)
        }
        XCTAssertThrowsError(try OPDSParser.parse(Data("not xml at all".utf8), url: URL(string: "https://example.com/")!))
        let rss = Data(#"<rss version="2.0"><channel><title>x</title></channel></rss>"#.utf8)
        XCTAssertThrowsError(try OPDSParser.parse(rss, url: URL(string: "https://example.com/")!))
    }

    func testFeedWithoutNamespaceOrTitle() throws {
        let data = Data("""
            <feed><entry><title>A</title><link rel="subsection" type="application/atom+xml" href="/a"/></entry></feed>
            """.utf8)
        let feed = try OPDSParser.parse(data, url: URL(string: "https://catalog.example.org/root")!)
        XCTAssertEqual(feed.title, "catalog.example.org", "falls back to the host")
        XCTAssertEqual(feed.entries.first?.navigationURL?.absoluteString, "https://catalog.example.org/a")
        XCTAssertEqual(feed.entries.first?.id, "https://catalog.example.org/a")
    }

    func testDeepNestingIsCut() throws {
        let deep = String(repeating: "<div>", count: 200) + "x" + String(repeating: "</div>", count: 200)
        let data = Data("""
            <feed xmlns="http://www.w3.org/2005/Atom"><title>Deep</title><entry><title>E</title>
            <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">\(deep)</div></content></entry></feed>
            """.utf8)
        let feed = try OPDSParser.parse(data, url: URL(string: "https://example.com/")!)
        XCTAssertEqual(feed.entries.map(\.title), ["E"])
    }

    // MARK: Catalog addresses

    func testCatalogAddressNormalisation() {
        XCTAssertEqual(OPDSCatalogAddress.normalize("  https://example.com/opds ")?.absoluteString, "https://example.com/opds")
        XCTAssertEqual(OPDSCatalogAddress.normalize("example.com/opds")?.absoluteString, "https://example.com/opds")
        XCTAssertEqual(OPDSCatalogAddress.normalize("books.example.net:8083/opds")?.absoluteString,
                       "https://books.example.net:8083/opds")
        XCTAssertEqual(OPDSCatalogAddress.normalize("http://192.168.1.20:8083/opds")?.absoluteString,
                       "http://192.168.1.20:8083/opds")
        XCTAssertEqual(OPDSCatalogAddress.normalize("opds://example.com/catalog.xml")?.absoluteString,
                       "https://example.com/catalog.xml")
        XCTAssertEqual(OPDSCatalogAddress.normalize("HTTPS://Example.com/")?.host, "Example.com")
        XCTAssertNil(OPDSCatalogAddress.normalize(""))
        XCTAssertNil(OPDSCatalogAddress.normalize("ftp://example.com/opds"))
        XCTAssertNil(OPDSCatalogAddress.normalize("javascript:alert(1)"))
        XCTAssertNil(OPDSCatalogAddress.normalize("file:///etc/passwd"))
        XCTAssertNil(OPDSCatalogAddress.normalize("my catalog"))
        XCTAssertNil(OPDSCatalogAddress.normalize("https://"))
        XCTAssertNil(OPDSCatalogAddress.normalize("https://user:secret@example.com/opds"), "no credentials in addresses")
    }

    func testPresetsAreNotContactedUntilOpened() async throws {
        XCTAssertEqual(OPDSCatalog.presets.map(\.title), ["Standard Ebooks", "Project Gutenberg"])
        XCTAssertTrue(OPDSCatalog.presets.allSatisfy { $0.isPreset && $0.url.scheme == "https" })
        let transport = MockOPDSTransport()
        let client = OPDSClient(transport: transport)
        let log = await client.requestLog
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testCatalogCodableRoundTrip() throws {
        let catalog = OPDSCatalog(title: "Home", url: URL(string: "https://books.example.net/opds")!)
        let decoded = try JSONDecoder().decode(OPDSCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded, catalog)
        XCTAssertFalse(decoded.isPreset)
    }

    // MARK: Client

    func testClientResolvesAgainstRedirectedURL() async throws {
        let transport = MockOPDSTransport()
        let requested = URL(string: "https://books.example.net/opds")!
        let served = URL(string: "https://books.example.net:8083/opds/")!
        transport.responses[requested] = (try fixture("calibreweb-root.xml"), 200, served)
        let client = OPDSClient(transport: transport)
        let feed = try await client.feed(at: requested)
        XCTAssertEqual(feed.url, served)
        XCTAssertEqual(feed.entries.first?.navigationURL?.absoluteString, "https://books.example.net:8083/opds/books")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url, requested)
        XCTAssertEqual(sent.headers["User-Agent"], OPDSClient.userAgent)
        XCTAssertTrue(sent.headers["Accept"]?.hasPrefix("application/atom+xml;profile=opds-catalog") == true)
        XCTAssertEqual(Set(sent.headers.keys), ["User-Agent", "Accept"], "nothing else is sent")
    }

    func testClientErrors() async throws {
        let transport = MockOPDSTransport()
        let client = OPDSClient(transport: transport)
        let url = URL(string: "https://standardebooks.org/feeds/opds")!
        for (status, expected) in [(401, OPDSError.authenticationRequired), (403, .authenticationRequired),
                                   (404, .notFound), (500, .server(status: 500))] {
            transport.responses[url] = (Data("<html/>".utf8), status, url)
            do {
                _ = try await client.feed(at: url)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? OPDSError, expected)
            }
        }
        transport.responses[url] = (Data("<html><body>Maintenance</body></html>".utf8), 200, url)
        do {
            _ = try await client.feed(at: url)
            XCTFail("a web page is not a feed")
        } catch {
            XCTAssertEqual(error as? OPDSError, .notAFeed)
        }
        XCTAssertEqual(OPDSClient.map(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(OPDSClient.map(URLError(.appTransportSecurityRequiresSecureConnection)), .httpNotAllowed)
        XCTAssertEqual(OPDSClient.map(URLError(.cannotFindHost)), .cannotFindHost)
        XCTAssertEqual(OPDSClient.map(URLError(.serverCertificateUntrusted)), .insecureConnection)
    }

    func testDownloadChecksTheFileIsAZIP() async throws {
        let transport = MockOPDSTransport()
        let client = OPDSClient(transport: transport)
        let link = OPDSLink(url: URL(string: "https://example.com/book.epub")!, rel: "http://opds-spec.org/acquisition",
                            type: "application/epub+zip")
        let epub = try Data(contentsOf: Self.fixtures.deletingLastPathComponent().appendingPathComponent("simple.epub"))
        transport.responses[link.url] = (epub, 200, link.url)
        let downloaded = try await client.download(link)
        XCTAssertEqual(downloaded, epub)
        XCTAssertEqual(transport.requests.last?.headers["Accept"], "application/epub+zip, */*;q=0.5")

        transport.responses[link.url] = (Data("<html>Please sign in</html>".utf8), 200, link.url)
        do {
            _ = try await client.download(link)
            XCTFail("an HTML page is not an EPUB")
        } catch {
            XCTAssertEqual(error as? OPDSError, .notAnEPUB)
        }
    }
}

/// Answers from a table; records what was asked.
final class MockOPDSTransport: OPDSTransport, @unchecked Sendable {
    struct Request { let url: URL; let headers: [String: String] }
    private let lock = NSLock()
    private var _responses: [URL: (Data, Int, URL)] = [:]
    private var _requests: [Request] = []

    var responses: [URL: (Data, Int, URL)] {
        get { lock.withLock { _responses } }
        set { lock.withLock { _responses = newValue } }
    }

    var requests: [Request] { lock.withLock { _requests } }

    func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int, url: URL) {
        let answer: (Data, Int, URL)? = lock.withLock {
            _requests.append(Request(url: url, headers: headers))
            return _responses[url]
        }
        guard let answer else { throw OPDSError.offline }
        return (answer.0, answer.1, answer.2)
    }
}
