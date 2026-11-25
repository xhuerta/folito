import XCTest
import ReaderCore
@testable import Folito

/// What the Library's search, sort and browse (#114) know about its rows, and the "Recently Read" activity the
/// watch's reports leave on a book.
final class LibraryBrowseFactsTests: XCTestCase {
    private func entry(_ hash: String, title: String = "T", author: String = "A", importedAt: Date = Date(timeIntervalSince1970: 100),
                       details: EPUBDetails? = nil) -> LibraryEntry {
        LibraryEntry(documentHash: hash, title: title, author: author, fileName: LibraryEntry.fileName(forHash: hash),
                     size: 1, importedAt: importedAt, sentToWatch: false, details: details)
    }

    func testLocalBookUsesEPUBAuthorsSeriesAndNewestActivity() {
        var local = entry("a", title: "Good Omens", author: "Terry Pratchett, Neil Gaiman",
                          details: EPUBDetails(title: "Good Omens",
                                               creators: [BookCreator(name: "Terry Pratchett", role: "aut"),
                                                          BookCreator(name: "Neil Gaiman", role: "aut")],
                                               series: BookSeries(name: "Omens", index: 1)))
        local.lastReadAt = Date(timeIntervalSince1970: 300)
        let cloud = ReadestCloudBook(hash: "a", title: "Good Omens", updatedAt: Date(timeIntervalSince1970: 200),
                                     uploadedAt: Date(timeIntervalSince1970: 150))
        let mark = ReadStatusMark(status: .finished, stamp: 400_000)
        let facts = LibraryBrowseFacts.facts(MergedLibraryItem(hash: "a", local: local, cloud: cloud), readStatus: mark)
        XCTAssertEqual(facts.authors, ["Terry Pratchett", "Neil Gaiman"])
        XCTAssertEqual(facts.series, BookSeries(name: "Omens", index: 1))
        XCTAssertEqual(facts.addedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(facts.lastReadAt, Date(timeIntervalSince1970: 400), "the status change is the newest activity")
        XCTAssertTrue(facts.isFinished)
    }

    func testLocalBookWithoutEPUBSeriesTakesTheReadestRowsAndSkipsTheUnknownAuthorPlaceholder() {
        let local = entry("a", author: BookDisplay.author(from: []))
        let cloud = ReadestCloudBook.parse(["book_hash": "a", "title": "T", "uploaded_at": "2024-01-01T00:00:00Z",
                                            "metadata": "{\"series\":\"Dune\",\"seriesIndex\":2}"])!
        let facts = LibraryBrowseFacts.facts(MergedLibraryItem(hash: "a", local: local, cloud: cloud), readStatus: nil)
        XCTAssertEqual(facts.series, BookSeries(name: "Dune", index: 2))
        XCTAssertEqual(facts.authors, [String](), "no author, not an author called “Unknown author”")
        XCTAssertFalse(facts.isFinished)
    }

    func testReadestOnlyBook() {
        let book = ReadestCloudBook.parse(["book_hash": "r", "title": "Dune Messiah", "author": "Frank Herbert",
                                           "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-02-01T00:00:00Z",
                                           "uploaded_at": "2024-01-02T00:00:00Z",
                                           "metadata": ["series": "Dune", "seriesIndex": 2]])!
        let facts = LibraryBrowseFacts.facts(MergedLibraryItem(hash: "r", local: nil, cloud: book), readStatus: nil)
        XCTAssertEqual(facts.title, "Dune Messiah")
        XCTAssertEqual(facts.authors, ["Frank Herbert"])
        XCTAssertEqual(facts.series, BookSeries(name: "Dune", index: 2))
        XCTAssertEqual(facts.addedAt, book.createdAt)
        XCTAssertEqual(facts.lastReadAt, book.updatedAt)
        XCTAssertTrue(LibrarySearch.matches("dune", facts))

        let anonymous = ReadestCloudBook(hash: "s", title: "Beowulf", author: " ", uploadedAt: Date(timeIntervalSince1970: 5))
        let other = LibraryBrowseFacts.facts(MergedLibraryItem(hash: "s", local: nil, cloud: anonymous), readStatus: nil)
        XCTAssertEqual(other.authors, [String]())
        XCTAssertEqual(other.addedAt, Date(timeIntervalSince1970: 5), "no created_at: the upload time")
    }

    @MainActor
    func testWatchProgressMovesLastReadOnlyWhenThePositionChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let books = dir.appendingPathComponent("Books", isDirectory: true)
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        let entries = [entry("a"), entry("b")]
        for e in entries { try Data([1]).write(to: books.appendingPathComponent(e.fileName)) }
        try JSONEncoder().encode(entries).write(to: dir.appendingPathComponent("library.json"))
        let store = LibraryStore(rootDirectory: dir)

        let first = Date(timeIntervalSince1970: 1000)
        store.noteWatchProgress(["a": 0.2, "b": 0], now: first)
        XCTAssertEqual(store.entries.first { $0.documentHash == "a" }?.lastReadAt, first)
        XCTAssertNil(store.entries.first { $0.documentHash == "b" }?.lastReadAt, "never opened")

        // The same report again (WatchConnectivity resends its context) is not reading.
        store.noteWatchProgress(["a": 0.2, "b": 0], now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(store.entries.first { $0.documentHash == "a" }?.lastReadAt, first)

        let later = Date(timeIntervalSince1970: 3000)
        store.noteWatchProgress(["a": 0.2, "b": 0.05], now: later)
        XCTAssertEqual(store.entries.first { $0.documentHash == "b" }?.lastReadAt, later)
        // Persisted.
        let reloaded = LibraryStore(rootDirectory: dir)
        XCTAssertEqual(reloaded.entries.first { $0.documentHash == "b" }?.lastReadAt, later)
        XCTAssertEqual(reloaded.entries.first { $0.documentHash == "b" }?.lastReadFraction, 0.05)
    }

    @MainActor
    func testSortAndBrowseNamesAreDistinct() {
        let sorts = Set(LibrarySortOrder.allCases.map { LibraryView.name(of: $0) })
        XCTAssertEqual(sorts.count, LibrarySortOrder.allCases.count)
        let modes = Set(LibraryBrowseMode.allCases.map { LibraryView.name(of: $0) })
        XCTAssertEqual(modes.count, LibraryBrowseMode.allCases.count)
    }

    // MARK: Collections (#164)

    @MainActor
    func testCollectionsPersistNextToTheLibraryAndNeverDeleteBooks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let books = dir.appendingPathComponent("Books", isDirectory: true)
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        let entries = [entry("a"), entry("b")]
        for e in entries { try Data([1]).write(to: books.appendingPathComponent(e.fileName)) }
        try JSONEncoder().encode(entries).write(to: dir.appendingPathComponent("library.json"))

        let store = LibraryStore(rootDirectory: dir)
        XCTAssertTrue(store.collections.isEmpty, "no collections.json yet")
        let toRead = try store.createCollection(named: "To Read", books: ["a"]).get()
        let club = try store.createCollection(named: "Book Club").get()
        XCTAssertEqual(store.createCollection(named: " to read "), .failure(.duplicate("To Read")))
        store.addBooks(["a", "b"], toCollection: club.id)
        store.moveCollection(club.id, by: -1)
        XCTAssertNil(store.renameCollection(toRead.id, to: "Up Next"))

        let reloaded = LibraryStore(rootDirectory: dir)
        XCTAssertEqual(reloaded.collections.collections.map(\.name), ["Book Club", "Up Next"])
        XCTAssertEqual(reloaded.collections.ids(containing: "a"), [club.id, toRead.id])

        reloaded.deleteCollection(club.id)
        XCTAssertEqual(reloaded.entries.count, 2, "deleting a collection keeps its books")
        XCTAssertEqual(LibraryStore(rootDirectory: dir).collections.collections.map(\.name), ["Up Next"])

        // A book deleted from the iPhone keeps its memberships (a Readest copy has the same hash).
        reloaded.delete(entries[0])
        XCTAssertEqual(reloaded.collections.ids(containing: "a"), [toRead.id])
    }

    @MainActor
    func testUnreadableCollectionsFileIsNoCollections() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("collections.json"))
        XCTAssertTrue(LibraryStore(rootDirectory: dir).collections.isEmpty)
    }

    func testFactsCarryTheCollectionsOfTheRow() throws {
        var collections = BookCollections()
        let one = try collections.create(named: "One", books: ["a"]).get()
        let item = MergedLibraryItem<LibraryEntry>(hash: "a", local: entry("a"), cloud: nil)
        XCTAssertEqual(LibraryBrowseFacts.facts(item, readStatus: nil, collections: collections).collectionIDs, [one.id])
        XCTAssertEqual(LibraryBrowseFacts.facts(item, readStatus: nil).collectionIDs, [])
    }
}
