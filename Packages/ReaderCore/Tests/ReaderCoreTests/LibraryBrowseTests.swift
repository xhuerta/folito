import Foundation
import XCTest
@testable import ReaderCore

/// Search, sort and browse of the iPhone Library (#114).
final class LibraryBrowseTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func book(_ title: String, _ authors: [String] = [], series: BookSeries? = nil, added: Double? = nil,
                      read: Double? = nil, finished: Bool = false) -> LibraryBookFacts {
        LibraryBookFacts(title: title, authors: authors, series: series,
                         addedAt: added.map { Date(timeIntervalSince1970: $0) },
                         lastReadAt: read.map { Date(timeIntervalSince1970: $0) }, isFinished: finished)
    }

    private func titles(_ items: [LibraryBookFacts]) -> [String] { items.map(\.title) }

    // MARK: Search normalisation

    func testNormalizeFoldsCaseAccentsWidthAndPunctuation() {
        XCTAssertEqual(LibrarySearch.normalize("Les Misérables"), "les miserables")
        XCTAssertEqual(LibrarySearch.normalize("ÉMILE ZOLA"), "emile zola")
        XCTAssertEqual(LibrarySearch.normalize("Alice’s  Adventures\n"), "alice's adventures")
        XCTAssertEqual(LibrarySearch.normalize("Ｆｕｌｌ"), "full")
        XCTAssertEqual(LibrarySearch.normalize("Straße"), "strasse")
        XCTAssertEqual(LibrarySearch.normalize("Søren Kierkegaard"), "soren kierkegaard")
        XCTAssertEqual(LibrarySearch.normalize("Œuvres"), "oeuvres")
        XCTAssertEqual(LibrarySearch.normalize("Jean‐Paul — “Sartre”"), "jean-paul - \"sartre\"")
        XCTAssertEqual(LibrarySearch.normalize("   "), "")
        XCTAssertEqual(LibrarySearch.terms("  Gods   OF mars "), ["gods", "of", "mars"])
    }

    func testSearchMatchesTitleAuthorAndSeriesInAnyCaseOrAccent() {
        let hugo = book("Les Misérables", ["Victor Hugo"])
        let mars = book("The Gods of Mars", ["Edgar Rice Burroughs"], series: BookSeries(name: "Barsoom", index: 2))
        XCTAssertTrue(LibrarySearch.matches("miserables", hugo))
        XCTAssertTrue(LibrarySearch.matches("MISÉRABLES", hugo))
        XCTAssertTrue(LibrarySearch.matches("hugo", hugo))
        XCTAssertTrue(LibrarySearch.matches("barsoom", mars), "series name")
        XCTAssertTrue(LibrarySearch.matches("mars burroughs", mars), "words may be in different fields")
        XCTAssertFalse(LibrarySearch.matches("mars hugo", mars), "every word must be found")
        XCTAssertTrue(LibrarySearch.matches("", mars), "a blank query matches everything")
        XCTAssertTrue(LibrarySearch.matches("   ", hugo))
        XCTAssertTrue(LibrarySearch.matches("alice's", book("Alice’s Adventures in Wonderland")), "typographic apostrophe")
        XCTAssertTrue(LibrarySearch.matches("vingt mille", book("Vingt Mille Lieues sous les mers", ["Jules Verne"])))
        XCTAssertTrue(LibrarySearch.matches("吾輩", book("吾輩は猫である", ["夏目漱石"])))
        XCTAssertFalse(LibrarySearch.matches("zzz", hugo))
    }

    func testFilterKeepsOrder() {
        let items = [book("B Mars"), book("A Venus"), book("C Mars")]
        XCTAssertEqual(titles(LibrarySearch.filter(items, query: "mars") { $0 }), ["B Mars", "C Mars"])
        XCTAssertEqual(titles(LibrarySearch.filter(items, query: " ") { $0 }), ["B Mars", "A Venus", "C Mars"])
    }

    // MARK: Sort orders

    func testRecentlyReadPutsUnfinishedFirstNewestActivityFirst() {
        let items = [
            book("Imported long ago, read today", added: 10, read: 500),
            book("Finished yesterday", added: 20, read: 400, finished: true),
            book("Just imported", added: 450),
            book("Untouched", added: 5),
            book("No dates"),
        ]
        XCTAssertEqual(titles(LibraryBrowsing.sorted(items, by: .recentlyRead, locale: en) { $0 }),
                       ["Imported long ago, read today", "Just imported", "Untouched", "No dates", "Finished yesterday"])
    }

    func testRecentlyAddedIsNewestFirstAndStable() {
        let items = [book("A", added: 1), book("B", added: 3), book("C"), book("D", added: 3), book("E", added: 2)]
        XCTAssertEqual(titles(LibraryBrowsing.sorted(items, by: .recentlyAdded, locale: en) { $0 }), ["B", "D", "E", "A", "C"])
    }

    func testTitleOrderIgnoresCaseAndAccentsAndSortsNumbersNumerically() {
        let items = [book("Émile"), book("zebra"), book("Book 10"), book("book 2"), book("Apple"), book("emma")]
        XCTAssertEqual(titles(LibraryBrowsing.sorted(items, by: .title, locale: en) { $0 }),
                       ["Apple", "book 2", "Book 10", "Émile", "emma", "zebra"])
    }

    func testTitleTieBreaksOnAuthorThenKeepsOrder() {
        let items = [book("Emma", ["Z"]), book("Emma", ["A"]), book("Emma", ["A"], added: 9)]
        let sorted = LibraryBrowsing.sorted(items, by: .title, locale: en) { $0 }
        XCTAssertEqual(sorted.map { $0.authors.first }, ["A", "A", "Z"])
        XCTAssertNil(sorted[0].addedAt, "equal books keep their order")
    }

    func testAuthorOrderThenSeriesPositionThenTitle() {
        let items = [
            book("Warlord", ["Edgar Rice Burroughs"], series: BookSeries(name: "Barsoom", index: 3)),
            book("Emma", ["Jane Austen"]),
            book("Anonymous"),
            book("Princess", ["Edgar Rice Burroughs"], series: BookSeries(name: "Barsoom", index: 1)),
            book("Tarzan", ["Edgar Rice Burroughs"]),
            book("Gods", ["edgar rice burroughs"], series: BookSeries(name: "Barsoom", index: 2)),
            book("Persuasion", ["Jane Austen"]),
        ]
        XCTAssertEqual(titles(LibraryBrowsing.sorted(items, by: .author, locale: en) { $0 }),
                       ["Princess", "Gods", "Warlord", "Tarzan", "Emma", "Persuasion", "Anonymous"])
    }

    // MARK: Sections

    func testBooksModeIsOneSection() {
        let sections = LibraryBrowsing.sections([book("B"), book("A")], mode: .books, order: .title, locale: en) { $0 }
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].kind, .all)
        XCTAssertEqual(titles(sections[0].items), ["A", "B"])
        XCTAssertTrue(LibraryBrowsing.sections([LibraryBookFacts](), mode: .books, order: .title) { $0 }.isEmpty)
    }

    func testSeriesSectionsOrderByFractionalPosition() {
        let items = [
            book("Three", series: BookSeries(name: "Barsoom", index: 3)),
            book("Interlude", series: BookSeries(name: "Barsoom", index: 2.5)),
            book("Standalone", added: 2),
            book("Unnumbered", series: BookSeries(name: "Barsoom")),
            book("One", series: BookSeries(name: "barsoom", index: 1)),
            book("Two", series: BookSeries(name: "Barsoom", index: 2)),
            book("Ten", series: BookSeries(name: "Barsoom", index: 10)),
            book("Wizard", series: BookSeries(name: "Oz", index: 1)),
            book("Alone", added: 1),
            book("Blank series name", series: BookSeries(name: "  ", index: 1)),
            book("Ann", series: BookSeries(name: "Anne of Green Gables", index: 1)),
        ]
        let sections = LibraryBrowsing.sections(items, mode: .series, order: .title, locale: en) { $0 }
        XCTAssertEqual(sections.map(\.kind), [.series("Anne of Green Gables"), .series("Barsoom"), .series("Oz"), .noSeries])
        XCTAssertEqual(titles(sections[1].items), ["One", "Two", "Interlude", "Three", "Ten", "Unnumbered"])
        XCTAssertEqual(titles(sections[3].items), ["Alone", "Blank series name", "Standalone"], "no series: in the sort order")
        XCTAssertEqual(sections[1].id, "series:barsoom")
    }

    func testSeriesSectionNamedAsFirstBookInOrderWritesIt() {
        let items = [book("B", series: BookSeries(name: "the expanse", index: 2)),
                     book("A", series: BookSeries(name: "The Expanse", index: 1))]
        let sections = LibraryBrowsing.sections(items, mode: .series, order: .title, locale: en) { $0 }
        XCTAssertEqual(sections.map(\.kind), [.series("The Expanse")])
    }

    func testAuthorSectionsListABookUnderEachAuthor() {
        let items = [
            book("Good Omens", ["Terry Pratchett", "Neil Gaiman"], added: 3),
            book("Coraline", ["Neil Gaiman"], added: 2),
            book("Mort", ["terry pratchett"], added: 4),
            book("Beowulf", [], added: 9),
            book("Edda", ["  "], added: 1),
            book("Twice", ["Émile Zola", "Emile Zola"]),
        ]
        let sections = LibraryBrowsing.sections(items, mode: .authors, order: .recentlyAdded, locale: en) { $0 }
        XCTAssertEqual(sections.map(\.kind), [.author("Émile Zola"), .author("Neil Gaiman"), .author("terry pratchett"), .unknownAuthor])
        XCTAssertEqual(titles(sections[0].items), ["Twice"], "the same author twice counts once")
        XCTAssertEqual(titles(sections[1].items), ["Good Omens", "Coraline"])
        XCTAssertEqual(titles(sections[2].items), ["Mort", "Good Omens"], "named as the first book in order writes it")
        XCTAssertEqual(titles(sections[3].items), ["Beowulf", "Edda"])
        XCTAssertEqual(sections[3].id, "unknownAuthor")
        XCTAssertEqual(sections[1].id, "author:neil gaiman")
    }

    func testSectionsAfterSearchOnlyHoldMatches() {
        let items = [book("The Gods of Mars", ["Edgar Rice Burroughs"], series: BookSeries(name: "Barsoom", index: 2)),
                     book("Emma", ["Jane Austen"])]
        let found = LibrarySearch.filter(items, query: "mars") { $0 }
        let sections = LibraryBrowsing.sections(found, mode: .authors, order: .recentlyRead, locale: en) { $0 }
        XCTAssertEqual(sections.map(\.kind), [.author("Edgar Rice Burroughs")])
    }

    func testModesAndOrdersRoundTripTheirStoredValues() {
        for order in LibrarySortOrder.allCases { XCTAssertEqual(LibrarySortOrder(rawValue: order.rawValue), order) }
        for mode in LibraryBrowseMode.allCases { XCTAssertEqual(LibraryBrowseMode(rawValue: mode.rawValue), mode) }
        XCTAssertNil(LibrarySortOrder(rawValue: "bogus"))
    }

    // MARK: Reading activity

    func testReadingActivityCountsAMoveOfTheReportedFraction() {
        XCTAssertTrue(ReadingActivity.hasMoved(from: nil, to: 0.2))
        XCTAssertFalse(ReadingActivity.hasMoved(from: nil, to: 0))
        XCTAssertFalse(ReadingActivity.hasMoved(from: 0.2, to: 0.2))
        XCTAssertTrue(ReadingActivity.hasMoved(from: 0.2, to: 0.21))
        XCTAssertTrue(ReadingActivity.hasMoved(from: 0.5, to: 0), "going back to the start is reading too")
        XCTAssertFalse(ReadingActivity.hasMoved(from: 0.5, to: .nan))
    }

    // MARK: Readest rows

    private func row(_ fields: [String: Any]) -> ReadestCloudBook {
        var all: [String: Any] = ["book_hash": "h1", "title": "T", "author": "A", "format": "EPUB"]
        all.merge(fields) { _, new in new }
        return ReadestCloudBook.parse(all)!
    }

    func testReadestSeriesFromMetadataString() {
        let book = row(["metadata": "{\"title\":\"The Gods of Mars\",\"series\":\"Barsoom\",\"seriesIndex\":2.5}"])
        XCTAssertEqual(book.series, BookSeries(name: "Barsoom", index: 2.5))
    }

    func testReadestSeriesFromMetadataObjectAndStringIndex() {
        XCTAssertEqual(row(["metadata": ["series": "Oz", "seriesIndex": "3"]]).series, BookSeries(name: "Oz", index: 3))
        XCTAssertEqual(row(["metadata": ["series": "Oz"]]).series, BookSeries(name: "Oz", index: nil))
        XCTAssertEqual(row(["metadata": ["series": "Oz", "seriesIndex": "first"]]).series, BookSeries(name: "Oz", index: nil))
        XCTAssertEqual(row(["metadata": ["series": "Oz", "seriesIndex": true]]).series, BookSeries(name: "Oz", index: nil))
        XCTAssertEqual(row(["metadata": ["series": "Oz", "seriesIndex": 1]]).series, BookSeries(name: "Oz", index: 1))
    }

    func testReadestSeriesFromBelongsTo() {
        let one = row(["metadata": "{\"belongsTo\":{\"series\":{\"name\":\"Dune\",\"position\":\"2\"}}}"])
        XCTAssertEqual(one.series, BookSeries(name: "Dune", index: 2))
        let list = row(["metadata": ["belongsTo": ["series": [["name": " "], ["name": "Dune", "position": 1.5]]]]])
        XCTAssertEqual(list.series, BookSeries(name: "Dune", index: 1.5))
    }

    func testReadestRowWithoutSeries() {
        XCTAssertNil(row([:]).series)
        XCTAssertNil(row(["metadata": "{\"language\":\"en\"}"]).series)
        XCTAssertNil(row(["metadata": "not json"]).series)
        XCTAssertNil(row(["metadata": ["series": "   "]]).series)
        XCTAssertNil(row(["metadata": NSNull()]).series)
    }

    func testReadestCreatedAt() {
        let book = row(["created_at": "2024-05-01T10:00:00.000Z"])
        XCTAssertEqual(book.createdAt, ISO8601DateFormatter().date(from: "2024-05-01T10:00:00Z"))
        XCTAssertNil(row([:]).createdAt)
    }
}
