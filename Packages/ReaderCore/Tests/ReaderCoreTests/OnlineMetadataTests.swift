import XCTest
@testable import ReaderCore

/// Online lookup of missing details (docs/ONLINE_METADATA.md): request building, parsing of Open Library
/// answers (fixtures trimmed from real responses), scoring, the merge rules and the client's etiquette.
/// The transport is mocked: no test here touches the network.
final class OnlineMetadataTests: XCTestCase {

    // MARK: Fixtures (trimmed from real Open Library answers, 2026-11)

    static let booksJSON = #"""
    {"ISBN:9780141439518": {"url": "http://openlibrary.org/books/OL37076991M/Pride_and_Prejudice", "key": "/books/OL37076991M", "title": "Pride and Prejudice", "authors": [{"url": "http://openlibrary.org/authors/OL21594A/Jane_Austen", "name": "Jane Austen"}], "publishers": [{"name": "Penguin Books"}], "publish_date": "2003", "subjects": [{"name": "Fiction, Romance, Historical, Regency", "url": "https://openlibrary.org/subjects/fiction,_romance,_historical,_regency"}, {"name": "Brothers and sisters", "url": "https://openlibrary.org/subjects/brothers_and_sisters"}, {"name": "brothers and sisters", "url": "https://openlibrary.org/subjects/brothers_and_sisters"}], "cover": {"small": "https://covers.openlibrary.org/b/id/12645114-S.jpg", "medium": "https://covers.openlibrary.org/b/id/12645114-M.jpg", "large": "https://covers.openlibrary.org/b/id/12645114-L.jpg"}}}
    """#

    static let searchJSON = #"""
    {"numFound": 274, "docs": [
     {"author_name": ["Seth Grahame-Smith", "Jane Austen"], "cover_i": 6460474, "first_publish_year": 2009, "key": "/works/OL13028735W", "title": "Pride and Prejudice and Zombies"},
     {"author_name": ["Jane Austen"], "cover_i": 14348537, "first_publish_year": 1813, "key": "/works/OL66554W", "title": "Pride and Prejudice", "subject": ["Fiction, Romance, Historical, Regency", "Brothers and sisters"]},
     {"author_name": ["Jane Austen"], "first_publish_year": 1813, "key": "/works/OL15165350W", "title": "Pride and Prejudice"},
     {"author_name": ["Someone Else"], "key": "/works/OL1W", "title": "A Cookbook"},
     {"key": "/authors/OL21594A", "title": "Not a book key"}
    ]}
    """#

    static let editionJSON = #"{"key": "/books/OL37076991M", "works": [{"key": "/works/OL66554W"}]}"#
    static let workJSON = #"""
    {"key": "/works/OL66554W", "description": {"type": "/type/text", "value": "Pride and Prejudice is an 1813 novel of manners written by [Jane Austen](https://openlibrary.org/authors/OL21594A).\r\n\r\nMr. Bennet has five daughters. ([source][1])\r\n\r\n----------\r\nAlso contained in:\r\n - [Complete Novels](https://openlibrary.org/works/OL1W)\r\n\r\n  [1]: https://en.wikipedia.org/wiki/Pride_and_Prejudice"}}
    """#

    // MARK: ISBN

    func testISBNNormalisation() {
        XCTAssertEqual(ISBN.normalize("978-0-14-143951-8"), "9780141439518")
        XCTAssertEqual(ISBN.normalize("urn:isbn:9780141439518"), "9780141439518")
        XCTAssertEqual(ISBN.normalize("ISBN 0-14-143951-3"), "9780141439518")
        XCTAssertEqual(ISBN.normalize(" 0 14 143951 3 "), "9780141439518")
        XCTAssertNil(ISBN.normalize("9780141439519"), "bad check digit")
        XCTAssertNil(ISBN.normalize("0141439514"), "bad ISBN-10 check digit")
        XCTAssertNil(ISBN.normalize("12345"))
        XCTAssertNil(ISBN.normalize("1234567890123"), "not a 978/979 prefix")
        XCTAssertNil(ISBN.normalize(""))
    }

    func testISBN10To13() {
        XCTAssertEqual(ISBN.isbn13(fromISBN10: "0141439513"), "9780141439518")
        // Check digit X (value 10).
        XCTAssertEqual(ISBN.normalize("0-8044-2957-X"), "9780804429573")
        XCTAssertEqual(ISBN.isbn13(fromISBN10: "080442957X"), "9780804429573")
        XCTAssertNil(ISBN.isbn13(fromISBN10: "0804429571"))
        XCTAssertTrue(ISBN.isValid13("9780804429573"))
    }

    // MARK: Request building

    func testBooksURL() throws {
        XCTAssertEqual(OpenLibraryAPI.booksURL(isbn: "978-0-14-143951-8")?.absoluteString,
                       "https://openlibrary.org/api/books?bibkeys=ISBN:9780141439518&format=json&jscmd=data")
        // An ISBN-10 is sent with its ISBN-13, in one request.
        XCTAssertEqual(OpenLibraryAPI.booksURL(isbn: "0141439513")?.absoluteString,
                       "https://openlibrary.org/api/books?bibkeys=ISBN:9780141439518,ISBN:0141439513&format=json&jscmd=data")
        XCTAssertNil(OpenLibraryAPI.booksURL(isbn: "not an isbn"))
    }

    func testSearchURLEscaping() throws {
        let url = try XCTUnwrap(OpenLibraryAPI.searchURL(title: "Me & You + Them = Us?", author: "Brontë, Anne"))
        XCTAssertEqual(url.absoluteString,
                       "https://openlibrary.org/search.json?title=Me%20You%20Them%20%3D%20Us&author=Bront%C3%AB,%20Anne"
                       + "&limit=10&fields=key,title,author_name,first_publish_year,cover_i,subject")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "Me You Them = Us")
        XCTAssertEqual(items.first { $0.name == "author" }?.value, "Brontë, Anne")
        XCTAssertEqual(items.count, 4, "a value can never add a parameter")
        // Solr syntax and line breaks become spaces.
        XCTAssertEqual(OpenLibraryAPI.searchTerm("Dune: \"Messiah\" (Book 2)\n"), "Dune Messiah Book 2")
        XCTAssertNil(OpenLibraryAPI.searchURL(title: " :: ", author: nil))
        XCTAssertFalse(try XCTUnwrap(OpenLibraryAPI.searchURL(title: "Emma", author: nil)).absoluteString.contains("author="))
    }

    func testRecordAndCoverURLs() {
        XCTAssertEqual(OpenLibraryAPI.recordURL(key: "/works/OL66554W")?.absoluteString, "https://openlibrary.org/works/OL66554W.json")
        XCTAssertEqual(OpenLibraryAPI.recordURL(key: "/books/OL37076991M")?.absoluteString, "https://openlibrary.org/books/OL37076991M.json")
        XCTAssertNil(OpenLibraryAPI.recordURL(key: "/works/OL66554M"))
        XCTAssertNil(OpenLibraryAPI.recordURL(key: "https://evil.example/works/OL1W"))
        XCTAssertNil(OpenLibraryAPI.recordURL(key: "/works/OL1W/../x"))
        XCTAssertEqual(OpenLibraryAPI.coverURL(id: 12645114, size: "L").absoluteString,
                       "https://covers.openlibrary.org/b/id/12645114-L.jpg?default=false")
        XCTAssertTrue(OpenLibraryAPI.userAgent.contains("https://folito.app"))
    }

    // MARK: Parsing

    func testParseBooks() throws {
        let match = try XCTUnwrap(OpenLibraryAPI.parseBooks(Data(Self.booksJSON.utf8)))
        XCTAssertEqual(match.key, "/books/OL37076991M")
        XCTAssertEqual(match.title, "Pride and Prejudice")
        XCTAssertEqual(match.authors, ["Jane Austen"])
        XCTAssertEqual(match.year, 2003)
        XCTAssertEqual(match.publisher, "Penguin Books")
        XCTAssertEqual(match.subjects, ["Fiction, Romance, Historical, Regency", "Brothers and sisters"], "deduplicated")
        XCTAssertEqual(match.coverID, 12645114)
        XCTAssertTrue(match.matchedByISBN)
        XCTAssertEqual(match.pageURL?.absoluteString, "https://openlibrary.org/books/OL37076991M")
        XCTAssertNil(try OpenLibraryAPI.parseBooks(Data("{}".utf8)), "unknown ISBN")
        XCTAssertThrowsError(try OpenLibraryAPI.parseBooks(Data("[]".utf8)))
    }

    func testParseSearch() throws {
        let matches = try OpenLibraryAPI.parseSearch(Data(Self.searchJSON.utf8))
        XCTAssertEqual(matches.map(\.key), ["/works/OL13028735W", "/works/OL66554W", "/works/OL15165350W", "/works/OL1W"])
        XCTAssertEqual(matches[1].year, 1813)
        XCTAssertEqual(matches[1].coverID, 14348537)
        XCTAssertNil(matches[2].coverID)
        XCTAssertFalse(matches[1].matchedByISBN)
        XCTAssertThrowsError(try OpenLibraryAPI.parseSearch(Data("{\"error\": 1}".utf8)))
    }

    func testParseRecordAndCleanDescription() throws {
        let edition = try OpenLibraryAPI.parseRecord(Data(Self.editionJSON.utf8))
        XCTAssertNil(edition.description)
        XCTAssertEqual(edition.workKey, "/works/OL66554W")
        let work = try OpenLibraryAPI.parseRecord(Data(Self.workJSON.utf8))
        XCTAssertEqual(work.description, "Pride and Prejudice is an 1813 novel of manners written by Jane Austen.\n\nMr. Bennet has five daughters.")
        XCTAssertEqual(try OpenLibraryAPI.parseRecord(Data(#"{"description": "Plain <b>text</b>."}"#.utf8)).description, "Plain text.")
        XCTAssertNil(try OpenLibraryAPI.parseRecord(Data(#"{"description": "  "}"#.utf8)).description)
    }

    // MARK: Scoring

    func testScoringRanksTheRightBookFirst() throws {
        let query = OnlineLookupQuery(isbn: nil, title: "Pride and Prejudice", authors: ["Jane Austen"])
        let ranked = MatchScoring.rank(try OpenLibraryAPI.parseSearch(Data(Self.searchJSON.utf8)), for: query)
        XCTAssertEqual(ranked.map(\.key), ["/works/OL66554W", "/works/OL15165350W", "/works/OL13028735W"],
                       "exact title first (ties keep Open Library's order); the cookbook is dropped")
        XCTAssertEqual(MatchScoring.score(ranked[0], for: query), 1, accuracy: 0.001)
        // Two works with the same title and author: duplicates, still confident.
        XCTAssertTrue(MatchScoring.isConfident(ranked, for: query))
    }

    func testScoringNormalisesAndFoldsAuthors() {
        let match = OnlineBookMatch(key: "/works/OL1W", title: "Los miserables", authors: ["Victor Hugo"])
        let query = OnlineLookupQuery(isbn: nil, title: "LOS MISERABLES", authors: ["Hugo, Victor"])
        XCTAssertEqual(MatchScoring.score(match, for: query), 1, accuracy: 0.001)
        XCTAssertEqual(MatchScoring.words("Les Misérables!"), ["miserables"])
        XCTAssertEqual(MatchScoring.similarity("Dune Messiah", "Dune"), 2.0 / 3.0, accuracy: 0.001)
        // A subtitle does not hurt the title score.
        let sub = OnlineBookMatch(key: "/works/OL2W", title: "Frankenstein; or, The Modern Prometheus", authors: ["Mary Shelley"])
        XCTAssertGreaterThan(MatchScoring.score(sub, for: OnlineLookupQuery(isbn: nil, title: "Frankenstein", authors: ["Mary Shelley"])), 0.5)
    }

    func testAmbiguousMatchesAreNotConfident() {
        let query = OnlineLookupQuery(isbn: nil, title: "Emma", authors: [])
        let a = OnlineBookMatch(key: "/works/OL1W", title: "Emma", authors: ["Jane Austen"])
        let b = OnlineBookMatch(key: "/works/OL2W", title: "Emma", authors: ["Someone Else"])
        XCTAssertFalse(MatchScoring.isConfident([a, b], for: query))
        XCTAssertTrue(MatchScoring.isConfident([a], for: query))
        let weak = OnlineBookMatch(key: "/works/OL3W", title: "Emma and the Dragon", authors: [])
        XCTAssertFalse(MatchScoring.isConfident([weak], for: query))
        XCTAssertTrue(MatchScoring.isConfident([OnlineBookMatch(key: "/books/OL1M", title: "X", matchedByISBN: true)], for: query))
        XCTAssertFalse(MatchScoring.isConfident([], for: query))
    }

    // MARK: Merge rules

    private let match = OnlineBookMatch(key: "/works/OL66554W", title: "Pride and Prejudice", authors: ["Jane Austen"],
                                        year: 1813, publisher: "T. Egerton", subjects: ["Fiction"],
                                        description: "From Open Library.", coverID: 1)

    func testMergeNeverOverwritesEPUBData() {
        let epub = EPUBDetails(title: "Pride and Prejudice", description: "From the EPUB.", publisher: "EPUB House",
                               year: 2001, subjects: ["Classics"])
        XCTAssertEqual(OnlineMetadataMerge.applicable(match, details: epub, hasEPUBCover: true, online: nil), [])
        XCTAssertNil(OnlineMetadataMerge.apply(match, selection: .all, details: epub, hasEPUBCover: true, online: nil,
                                               coverStored: true), "nothing is missing, nothing is applied")
        let merged = OnlineMetadataMerge.merged(details: epub, online: OnlineBookDetails(sourceKey: match.key,
                                                                                         description: "web", year: 1813,
                                                                                         publisher: "web", subjects: ["web"]))
        XCTAssertEqual(merged.description, SourcedValue(value: "From the EPUB.", source: .epub))
        XCTAssertEqual(merged.year, SourcedValue(value: 2001, source: .epub))
        XCTAssertEqual(merged.publisher?.source, .epub)
        XCTAssertEqual(merged.subjects?.value, ["Classics"])
    }

    func testMergeFillsOnlyMissingFields() throws {
        // The EPUB has a year but no description, publisher, subjects or cover.
        let epub = EPUBDetails(title: "Pride and Prejudice", description: "  ", year: 2001)
        XCTAssertEqual(OnlineMetadataMerge.missing(details: epub, hasEPUBCover: false), .all)
        XCTAssertTrue(OnlineMetadataMerge.needsLookup(details: epub, hasEPUBCover: false, online: nil))
        let online = try XCTUnwrap(OnlineMetadataMerge.apply(match, selection: .all, details: epub, hasEPUBCover: false,
                                                             online: nil, coverStored: true))
        XCTAssertEqual(online.description, "From Open Library.")
        XCTAssertNil(online.year, "the EPUB's year stays")
        XCTAssertEqual(online.publisher, "T. Egerton")
        XCTAssertEqual(online.subjects, ["Fiction"])
        XCTAssertTrue(online.hasCover)
        let merged = OnlineMetadataMerge.merged(details: epub, online: online)
        XCTAssertEqual(merged.description?.source, .openLibrary)
        XCTAssertEqual(merged.year, SourcedValue(value: 2001, source: .epub))
        XCTAssertFalse(OnlineMetadataMerge.needsLookup(details: epub, hasEPUBCover: false, online: online))
    }

    func testCoverAndDescriptionAreSeparateChoices() throws {
        let epub = EPUBDetails(title: "Pride and Prejudice")
        let coverOnly = try XCTUnwrap(OnlineMetadataMerge.apply(match, selection: .cover, details: epub, hasEPUBCover: false,
                                                                online: nil, coverStored: true))
        XCTAssertTrue(coverOnly.hasCover)
        XCTAssertNil(coverOnly.description)
        XCTAssertNil(coverOnly.year)
        // Then the description, on top: the cover stays.
        let both = try XCTUnwrap(OnlineMetadataMerge.apply(match, selection: .description, details: epub, hasEPUBCover: false,
                                                           online: coverOnly, coverStored: false))
        XCTAssertTrue(both.hasCover)
        XCTAssertEqual(both.description, "From Open Library.")
        // A cover that could not be downloaded is not recorded.
        XCTAssertNil(OnlineMetadataMerge.apply(match, selection: .cover, details: epub, hasEPUBCover: false, online: nil,
                                               coverStored: false))
        // The EPUB's own cover is never replaced.
        XCTAssertFalse(OnlineMetadataMerge.applicable(match, details: epub, hasEPUBCover: true, online: nil).contains(.cover))
        // A match without a cover or description offers neither.
        let bare = OnlineBookMatch(key: "/works/OL9W", title: "Pride and Prejudice")
        XCTAssertEqual(OnlineMetadataMerge.applicable(bare, details: epub, hasEPUBCover: false, online: nil), [])
    }

    // MARK: Client (mocked transport)

    func testLookupByISBNThenSearch() async throws {
        let transport = MockTransport([
            "/api/books": [(200, Data("{}".utf8), nil)],
            "/search.json": [(200, Data(Self.searchJSON.utf8), nil)],
        ])
        let client = OpenLibraryClient(transport: transport, sleep: { _ in })
        let matches = try await client.lookup(OnlineLookupQuery(isbn: "9780141439518", title: "Pride and Prejudice",
                                                                authors: ["Jane Austen", "Second Author"]))
        XCTAssertEqual(matches.first?.key, "/works/OL66554W")
        let log = await client.requestLog
        XCTAssertEqual(log.map(\.path), ["/api/books", "/search.json"], "ISBN first, then search")
        XCTAssertFalse(log[1].absoluteString.contains("Second"), "only the first author is sent")
        let headers = transport.headers
        XCTAssertEqual(headers.first?["User-Agent"], OpenLibraryAPI.userAgent)
        XCTAssertEqual(Set(headers.flatMap(\.keys)), ["User-Agent", "Accept"], "no other header, no personal data")
    }

    func testISBNMatchSkipsSearch() async throws {
        let transport = MockTransport(["/api/books": [(200, Data(Self.booksJSON.utf8), nil)]])
        let client = OpenLibraryClient(transport: transport, sleep: { _ in })
        let matches = try await client.lookup(OnlineLookupQuery(isbn: "0141439513", title: "x", authors: []))
        XCTAssertEqual(matches.map(\.key), ["/books/OL37076991M"])
        let count = await client.requestLog.count
        XCTAssertEqual(count, 1)
    }

    func testDescriptionFollowsTheWork() async throws {
        let transport = MockTransport([
            "/books/OL37076991M.json": [(200, Data(Self.editionJSON.utf8), nil)],
            "/works/OL66554W.json": [(200, Data(Self.workJSON.utf8), nil)],
        ])
        let client = OpenLibraryClient(transport: transport, sleep: { _ in })
        let match = try XCTUnwrap(OpenLibraryAPI.parseBooks(Data(Self.booksJSON.utf8)))
        let text = try await client.description(for: match)
        XCTAssertTrue(text?.hasPrefix("Pride and Prejudice is an 1813 novel") == true)
    }

    func testCoverMissingIsNil() async throws {
        let transport = MockTransport(["/b/id/1-L.jpg": [(404, Data(), nil)], "/b/id/2-L.jpg": [(200, Data([0xFF, 0xD8]), nil)]])
        let client = OpenLibraryClient(transport: transport, sleep: { _ in })
        let missing = try await client.cover(for: OnlineBookMatch(key: "/works/OL1W", title: "a", coverID: 1))
        XCTAssertNil(missing)
        let found = try await client.cover(for: OnlineBookMatch(key: "/works/OL1W", title: "a", coverID: 2))
        XCTAssertEqual(found, Data([0xFF, 0xD8]))
        let noCover = try await client.cover(for: OnlineBookMatch(key: "/works/OL1W", title: "a"))
        XCTAssertNil(noCover)
        XCTAssertTrue(transport.urls.allSatisfy { $0.query == "default=false" })
    }

    func testBackoffOn429And503() async throws {
        let sleeps = SleepLog()
        let transport = MockTransport(["/search.json": [(429, Data(), 7), (503, Data(), nil), (200, Data(Self.searchJSON.utf8), nil)]])
        let client = OpenLibraryClient(transport: transport, minimumInterval: 0, sleep: { await sleeps.add($0) })
        let matches = try await client.lookup(OnlineLookupQuery(isbn: nil, title: "Pride and Prejudice", authors: []))
        XCTAssertFalse(matches.isEmpty)
        let waits = await sleeps.values
        XCTAssertEqual(waits, [7, 4], "Retry-After honoured, then exponential backoff")
    }

    func testGivesUpAfterRetries() async {
        let transport = MockTransport(["/search.json": [(429, Data(), nil), (429, Data(), nil), (429, Data(), nil)]])
        let client = OpenLibraryClient(transport: transport, sleep: { _ in })
        do {
            _ = try await client.lookup(OnlineLookupQuery(isbn: nil, title: "Emma", authors: []))
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error as? OnlineMetadataError, .rateLimited)
        }
        let count = await client.requestLog.count
        XCTAssertEqual(count, 3)
    }

    func testServerErrorAndOffline() async {
        let client = OpenLibraryClient(transport: MockTransport(["/search.json": [(500, Data(), nil)]]), sleep: { _ in })
        do {
            _ = try await client.lookup(OnlineLookupQuery(isbn: nil, title: "Emma", authors: []))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? OnlineMetadataError, .server(status: 500))
        }
        let offline = OpenLibraryClient(transport: MockTransport([:], offline: true), sleep: { _ in })
        do {
            _ = try await offline.lookup(OnlineLookupQuery(isbn: nil, title: "Emma", authors: []))
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? OnlineMetadataError, .offline)
        }
    }

    func testRequestsAreSequentialAndSpaced() async throws {
        let sleeps = SleepLog()
        let clock = Clock()
        let transport = MockTransport(["/search.json": Array(repeating: (200, Data(Self.searchJSON.utf8), nil), count: 3)])
        let client = OpenLibraryClient(transport: transport, minimumInterval: 1,
                                       sleep: { await sleeps.add($0) }, now: { clock.now })
        let query = OnlineLookupQuery(isbn: nil, title: "Pride and Prejudice", authors: [])
        async let a = client.lookup(query)
        async let b = client.lookup(query)
        async let c = client.lookup(query)
        _ = try await (a, b, c)
        XCTAssertEqual(transport.maxConcurrent, 1, "one request at a time")
        let waits = await sleeps.values
        XCTAssertEqual(waits.count, 2, "the second and third requests wait for the interval")
        XCTAssertTrue(waits.allSatisfy { $0 > 0 && $0 <= 1 })
    }
}

// MARK: - Test doubles

/// Answers by URL path from a queue of canned responses; records URLs and headers; tracks concurrency.
final class MockTransport: MetadataTransport, @unchecked Sendable {
    typealias Response = (Int, Data, Double?)
    private let lock = NSLock()
    private var responses: [String: [Response]]
    private let offline: Bool
    private var inFlight = 0
    private(set) var maxConcurrent = 0
    private(set) var urls: [URL] = []
    private(set) var headers: [[String: String]] = []

    init(_ responses: [String: [Response]], offline: Bool = false) {
        self.responses = responses
        self.offline = offline
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int, retryAfter: Double?) {
        let next: Response? = lock.withLock {
            urls.append(url)
            self.headers.append(headers)
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
            guard var queue = responses[url.path], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            responses[url.path] = queue
            return first
        }
        await Task.yield()
        lock.withLock { inFlight -= 1 }
        if offline { throw OnlineMetadataError.offline }
        guard let next else { return (Data(), 404, nil) }
        return (next.1, next.0, next.2)
    }
}

actor SleepLog {
    private(set) var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
}

/// A clock that only moves when read, so spacing is deterministic.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 0)
    var now: Date {
        lock.withLock {
            t = t.addingTimeInterval(0.25)
            return t
        }
    }
}
