import XCTest
@testable import ReaderCore

/// OPDS search (OpenSearch 1.1, docs/OPDS.md): the `rel="search"` links of feeds, OpenSearch description documents,
/// filling templates, and searching through the client with the sign-in rules of part 2. The transport is mocked.
///
/// Fixtures (Tests/Fixtures/OPDS): `opensearch-*.xml` are description documents and `search-*-results.xml` result
/// pages, written by hand in the shape Calibre-Web, Project Gutenberg, Komga, Kavita and Standard Ebooks produce
/// (no server is contacted); `opensearch-unusable.xml` holds the templates Folito must refuse.
final class OPDSSearchTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/OPDS")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    private func parse(_ name: String, url: String) throws -> OPDSFeed {
        try OPDSParser.parse(fixture(name), url: URL(string: url)!)
    }

    private func description(_ name: String, url: String) throws -> OPDSSearchTemplate {
        try OPDSOpenSearch.parseDescription(fixture(name), url: URL(string: url)!)
    }

    // MARK: Search links of feeds

    func testFeedSearchLinks() throws {
        // Calibre-Web lists the description and a direct template: the template is used (one request fewer).
        let calibreWeb = try parse("calibreweb-root.xml", url: "https://books.example.net:8083/opds")
        guard case .template(let cwTemplate)? = calibreWeb.search else { return XCTFail("\(String(describing: calibreWeb.search))") }
        XCTAssertEqual(cwTemplate.template, "/opds/search/{searchTerms}")
        XCTAssertEqual(cwTemplate.url(for: "the time")?.absoluteString,
                       "https://books.example.net:8083/opds/search/the%20time")

        // Its acquisition pages list only the description.
        let calibreWebNew = try parse("calibreweb-new.xml", url: "https://books.example.net:8083/opds/new")
        XCTAssertEqual(calibreWebNew.search, .description(URL(string: "https://books.example.net:8083/opds/osd")!))

        // Calibre's content server: a template with a query of its own.
        let calibre = try parse("calibre-root.xml", url: "https://calibre.example.net:8080/opds")
        guard case .template(let cTemplate)? = calibre.search else { return XCTFail("no Calibre template") }
        XCTAssertEqual(cTemplate.url(for: "persuasion")?.absoluteString,
                       "https://calibre.example.net:8080/opds/search/persuasion?library_id=Calibre_Library")

        XCTAssertEqual(try parse("gutenberg-root.xml", url: "https://www.gutenberg.org/ebooks.opds/").search,
                       .description(URL(string: "https://www.gutenberg.org/catalog/osd-books.xml")!))
        XCTAssertEqual(try parse("komga-root.xml", url: "https://komga.example.net/opds/v1.2/catalog").search,
                       .description(URL(string: "https://komga.example.net/opds/v1.2/search")!))
        XCTAssertEqual(try parse("standardebooks-new-releases.xml", url: "https://standardebooks.org/feeds/atom/new-releases").search,
                       .description(URL(string: "https://standardebooks.org/opensearch")!))
        // No search link: no search field.
        XCTAssertNil(try parse("kavita-series.xml", url: "https://kavita.example.net/api/opds/x/series/3").search)
        // A search link is not where an entry leads, nor an entry.
        XCTAssertFalse(calibreWeb.entries.contains { $0.navigationURL?.absoluteString.contains("search") == true })
    }

    func testOddSearchLinksAreIgnored() throws {
        let xml = """
            <feed xmlns="http://www.w3.org/2005/Atom"><title>Odd</title>
            <link rel="search" type="text/html" href="https://example.org/search?q={searchTerms}"/>
            <link rel="search" type="application/atom+xml" href="https://example.org/opds/search?q={searchTerms}&amp;n={count}"/>
            <link rel="search" type="application/opensearchdescription+xml" href="javascript:alert(1)"/>
            </feed>
            """
        XCTAssertNil(try OPDSParser.parse(Data(xml.utf8), url: URL(string: "https://example.org/opds")!).search)
    }

    // MARK: Templates

    func testTemplateFilling() {
        let base = URL(string: "https://example.org/opds/")!
        func url(_ template: String, _ terms: String = "Jane Austen") -> String? {
            OPDSSearchTemplate(template: template, base: base, indexOffset: 0, pageOffset: 1).url(for: terms)?.absoluteString
        }
        XCTAssertEqual(url("search?q={searchTerms}"), "https://example.org/opds/search?q=Jane%20Austen")
        // Everything but letters, digits and -._~ is encoded, so terms are safe in a path segment too.
        XCTAssertEqual(url("/s/{searchTerms}", "a/b?c&d=e#f+g"), "https://example.org/s/a%2Fb%3Fc%26d%3De%23f%2Bg")
        XCTAssertEqual(url("/s?q={searchTerms}", "  Gödel, Escher  "), "https://example.org/s?q=G%C3%B6del%2C%20Escher")
        XCTAssertEqual(url("/s?q={searchTerms}", "日本"), "https://example.org/s?q=%E6%97%A5%E6%9C%AC")
        // Optional parameters are left empty; required standard ones get their first-page values.
        XCTAssertEqual(url("/s?q={searchTerms}&p={startPage?}&l={language?}"), "https://example.org/s?q=Jane%20Austen&p=&l=")
        XCTAssertEqual(url("/s?q={searchTerms}&i={startIndex}&p={startPage}&l={language}&e={inputEncoding}"),
                       "https://example.org/s?q=Jane%20Austen&i=0&p=1&l=*&e=UTF-8")
        XCTAssertEqual(url("/s?q={opensearch:searchTerms}"), "https://example.org/s?q=Jane%20Austen")
        XCTAssertEqual(url("/s?q={searchTerms?}"), "https://example.org/s?q=Jane%20Austen")
        // Unusable: a required parameter Folito has no value for, no terms, an unclosed brace, another scheme.
        XCTAssertNil(url("/s?q={searchTerms}&n={count}"))
        XCTAssertNil(url("/s?q={geo:box}&t={searchTerms}"))
        XCTAssertNil(url("/s?sort=new"))
        XCTAssertNil(url("/s?q={searchTerms"))
        XCTAssertNil(url("javascript:alert('{searchTerms}')"))
        XCTAssertNil(url("ftp://example.org/{searchTerms}"))
        // Nothing to search for.
        XCTAssertNil(url("/s?q={searchTerms}", "   "))
    }

    // MARK: Description documents

    func testDescriptionDocuments() throws {
        // Calibre-Web: relative templates, the HTML one first.
        XCTAssertEqual(try description("opensearch-calibreweb.xml", url: "https://books.example.net:8083/opds/osd")
                        .url(for: "time machine")?.absoluteString,
                       "https://books.example.net:8083/opds/search?query=time%20machine")
        // Project Gutenberg: suggestions and HTML are skipped; an optional start index is left empty.
        XCTAssertEqual(try description("opensearch-gutenberg.xml", url: "https://www.gutenberg.org/catalog/osd-books.xml")
                        .url(for: "Jane Austen")?.absoluteString,
                       "https://www.gutenberg.org/ebooks/search.opds/?query=Jane%20Austen&start_index=")
        // Komga: `kind=acquisition` in the type.
        XCTAssertEqual(try description("opensearch-komga.xml", url: "https://komga.example.net/opds/v1.2/search")
                        .url(for: "austen")?.absoluteString,
                       "https://komga.example.net/opds/v1.2/search?search=austen")
        // Kavita: the API key is in the path of the template too.
        XCTAssertEqual(try description("opensearch-kavita.xml", url: "https://kavita.example.net/api/opds/00000000-0000-0000-0000-00000000test/search")
                        .url(for: "persuasion")?.absoluteString,
                       "https://kavita.example.net/api/opds/00000000-0000-0000-0000-00000000test/series?query=persuasion")
        // Standard Ebooks: the Atom template, not HTML or RSS.
        XCTAssertEqual(try description("opensearch-standardebooks.xml", url: "https://standardebooks.org/opensearch")
                        .url(for: "dickens")?.absoluteString,
                       "https://standardebooks.org/feeds/atom/all?query=dickens")
    }

    func testOPDSProfileIsPreferred() throws {
        let xml = """
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
            <Url type="application/atom+xml" template="/atom?q={searchTerms}"/>
            <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="/opds?q={searchTerms}"/>
            </OpenSearchDescription>
            """
        let template = try OPDSOpenSearch.parseDescription(Data(xml.utf8), url: URL(string: "https://example.org/osd")!)
        XCTAssertEqual(template.url(for: "x")?.absoluteString, "https://example.org/opds?q=x")
    }

    func testUnusableDescriptions() throws {
        XCTAssertThrowsError(try description("opensearch-unusable.xml", url: "https://books.example.org/osd")) {
            XCTAssertEqual($0 as? OPDSError, .searchNotSupported)
        }
        XCTAssertThrowsError(try OPDSOpenSearch.parseDescription(Data("<html><body>Login</body></html>".utf8),
                                                                 url: URL(string: "https://example.org/osd")!)) {
            XCTAssertEqual($0 as? OPDSError, .notAFeed)
        }
        XCTAssertThrowsError(try description("calibreweb-root.xml", url: "https://example.org/osd")) {
            XCTAssertEqual($0 as? OPDSError, .notAFeed, "a feed is not a description")
        }
    }

    // MARK: Result pages

    func testResultPages() throws {
        let cw = try parse("search-calibreweb-results.xml", url: "https://books.example.net:8083/opds/search?query=wells")
        XCTAssertEqual(cw.kind, .acquisition)
        XCTAssertEqual(cw.entries.map(\.title), ["The Time Machine", "The War of the Worlds"])
        XCTAssertEqual(cw.entries.first?.epubLink?.url.absoluteString, "https://books.example.net:8083/opds/download/12/epub/")
        XCTAssertEqual(cw.nextURL?.absoluteString, "https://books.example.net:8083/opds/search/wells?offset=30")

        let pg = try parse("search-gutenberg-results.xml", url: "https://www.gutenberg.org/ebooks/search.opds/?query=jane%20austen")
        XCTAssertEqual(pg.entries.map(\.title), ["Pride and Prejudice", "Emma"])
        XCTAssertEqual(pg.entries.first?.navigationURL?.absoluteString, "https://www.gutenberg.org/ebooks/1342.opds")
        XCTAssertEqual(pg.nextURL?.absoluteString, "https://www.gutenberg.org/ebooks/search.opds/?query=jane%20austen&start_index=26")

        // Komga finds series: navigation entries.
        let komga = try parse("search-komga-results.xml", url: "https://komga.example.net/opds/v1.2/search?search=austen")
        XCTAssertEqual(komga.entries.map(\.kind), [.navigation])
        XCTAssertEqual(komga.entries.first?.navigationURL?.absoluteString, "https://komga.example.net/opds/v1.2/series/0BWJ8M1QH4ZR6")
    }

    // MARK: Client

    func testClientReadsTheDescriptionOnceThenSearches() async throws {
        let transport = MockOPDSTransport()
        let osd = URL(string: "https://books.example.net:8083/opds/osd")!
        transport.responses[osd] = (try fixture("opensearch-calibreweb.xml"), 200, osd)
        let wells = URL(string: "https://books.example.net:8083/opds/search?query=wells")!
        let verne = URL(string: "https://books.example.net:8083/opds/search?query=jules%20verne")!
        transport.responses[wells] = (try fixture("search-calibreweb-results.xml"), 200, wells)
        transport.responses[verne] = (Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Calibre-Web</title></feed>".utf8), 200, verne)
        let client = OPDSClient(transport: transport)

        let empty = try await client.search(.description(osd), terms: "  ")
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty, "nothing is contacted until there is something to search for")

        let results = try await client.search(.description(osd), terms: "wells")
        XCTAssertEqual(results.entries.count, 2)
        let none = try await client.search(.description(osd), terms: "jules verne")
        XCTAssertTrue(none.entries.isEmpty)
        XCTAssertEqual(transport.requests.map(\.url), [osd, wells, verne], "the description is read once")
        XCTAssertTrue(transport.requests[0].headers["Accept"]?.hasPrefix("application/opensearchdescription+xml") == true)
        XCTAssertTrue(transport.requests[1].headers["Accept"]?.hasPrefix("application/atom+xml") == true)
        XCTAssertEqual(Set(transport.requests[1].headers.keys), ["User-Agent", "Accept"], "nothing else is sent")
    }

    func testDirectTemplateNeedsNoDescription() async throws {
        let transport = MockOPDSTransport()
        let page = URL(string: "https://books.example.net:8083/opds")!
        let feed = try OPDSParser.parse(try fixture("calibreweb-root.xml"), url: page)
        let results = URL(string: "https://books.example.net:8083/opds/search/wells")!
        transport.responses[results] = (try fixture("search-calibreweb-results.xml"), 200, results)
        let client = OPDSClient(transport: transport)
        let found = try await client.search(try XCTUnwrap(feed.search), terms: "wells")
        XCTAssertEqual(found.entries.count, 2)
        XCTAssertEqual(transport.requests.map(\.url), [results])
    }

    func testSearchFollowsTheSignInRules() async throws {
        let transport = MockOPDSTransport()
        let reader = OPDSCredentials(username: "reader", password: "secret")
        let vault = OPDSCredentialVault()
        let server = URL(string: "https://books.example.net:8083/opds")!
        vault.set(reader, for: try XCTUnwrap(OPDSOrigin(server)))
        let client = OPDSClient(transport: transport, vault: vault)

        // The catalog's own description and results: signed in.
        let osd = URL(string: "https://books.example.net:8083/opds/osd")!
        let own = URL(string: "https://books.example.net:8083/opds/search?query=wells")!
        transport.responses[osd] = (try fixture("opensearch-calibreweb.xml"), 200, osd)
        transport.responses[own] = (try fixture("search-calibreweb-results.xml"), 200, own)
        _ = try await client.search(.description(osd), terms: "wells")

        // A template on another server, or on the same host over plain http: no sign-in sent.
        let foreign = OPDSSearchTemplate(template: "https://search.example.org/opds?q={searchTerms}", base: server)
        let foreignURL = URL(string: "https://search.example.org/opds?q=wells")!
        transport.responses[foreignURL] = (try fixture("search-calibreweb-results.xml"), 200, foreignURL)
        _ = try await client.search(.template(foreign), terms: "wells")
        let plain = OPDSSearchTemplate(template: "http://books.example.net:8083/opds/search?query={searchTerms}", base: server)
        let plainURL = URL(string: "http://books.example.net:8083/opds/search?query=wells")!
        transport.responses[plainURL] = (try fixture("search-calibreweb-results.xml"), 200, plainURL)
        _ = try await client.search(.template(plain), terms: "wells")

        XCTAssertEqual(transport.requests.map { $0.headers["Authorization"] },
                       [reader.authorizationHeader, reader.authorizationHeader, nil, nil])

        // A refused search is reported like a refused page.
        transport.responses[own] = (Data(), 401, own)
        do {
            _ = try await client.search(.description(osd), terms: "wells")
            XCTFail("expected credentialsRejected")
        } catch {
            XCTAssertEqual(error as? OPDSError, .credentialsRejected)
        }
    }

    func testUnusableDescriptionFromClient() async throws {
        let transport = MockOPDSTransport()
        let osd = URL(string: "https://books.example.org/osd")!
        transport.responses[osd] = (try fixture("opensearch-unusable.xml"), 200, osd)
        let client = OPDSClient(transport: transport)
        do {
            _ = try await client.search(.description(osd), terms: "x")
            XCTFail("expected searchNotSupported")
        } catch {
            XCTAssertEqual(error as? OPDSError, .searchNotSupported)
        }
        XCTAssertEqual(transport.requests.map(\.url), [osd], "no results request after an unusable description")
    }
}
