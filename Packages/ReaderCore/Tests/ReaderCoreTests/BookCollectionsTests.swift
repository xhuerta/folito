import Foundation
import XCTest
@testable import ReaderCore

/// User collections of the iPhone Library (#164): create, rename, reorder, delete, membership, persistence, and
/// *By Collection*.
final class BookCollectionsTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func make(_ names: [String]) -> BookCollections {
        var collections = BookCollections()
        for name in names { _ = collections.create(named: name, id: name.lowercased()) }
        return collections
    }

    private func names(_ collections: BookCollections) -> [String] { collections.collections.map(\.name) }

    // MARK: Create and rename

    func testCreateTrimsAndAppendsInOrder() throws {
        var collections = BookCollections()
        let first = try collections.create(named: "  To Read \n").get()
        XCTAssertEqual(first.name, "To Read")
        XCTAssertTrue(first.books.isEmpty)
        _ = try collections.create(named: "Book Club", books: ["a", "b", "a"]).get()
        XCTAssertEqual(names(collections), ["To Read", "Book Club"])
        XCTAssertEqual(collections.collections[1].books, ["a", "b"], "a book is in a collection once")
        XCTAssertNotEqual(collections.collections[0].id, collections.collections[1].id)
    }

    func testCreateRejectsBlankAndDuplicateNames() {
        var collections = make(["Sci-fi"])
        XCTAssertEqual(collections.create(named: "   "), .failure(.empty))
        XCTAssertEqual(collections.create(named: "SCI-FI"), .failure(.duplicate("Sci-fi")))
        XCTAssertEqual(collections.create(named: "Sci‐fi"), .failure(.duplicate("Sci-fi")), "typographic dash")
        XCTAssertEqual(names(collections), ["Sci-fi"])
    }

    func testCreateNeverReusesAnID() throws {
        var collections = make(["A"])
        let other = try collections.create(named: "B", id: "a").get()
        XCTAssertNotEqual(other.id, "a")
        XCTAssertEqual(collections.collections.count, 2)
    }

    func testRenameKeepsBooksAndPlace() {
        var collections = make(["To Read", "Book Club"])
        collections.add(["x"], to: "to read")
        XCTAssertNil(collections.rename("to read", to: " Up Next "))
        XCTAssertEqual(names(collections), ["Up Next", "Book Club"])
        XCTAssertEqual(collections.collection(id: "to read")?.books, ["x"])
        XCTAssertNil(collections.rename("to read", to: "UP NEXT"), "its own name in another case")
        XCTAssertEqual(collections.rename("to read", to: "book club"), .duplicate("Book Club"))
        XCTAssertEqual(collections.rename("to read", to: ""), .empty)
        XCTAssertEqual(names(collections), ["UP NEXT", "Book Club"])
        XCTAssertNil(collections.rename("missing", to: "X"))
    }

    // MARK: Order

    func testMoveLikeListOnMove() {
        var collections = make(["A", "B", "C", "D"])
        collections.move(fromOffsets: [0], toOffset: 3)   // A after C
        XCTAssertEqual(names(collections), ["B", "C", "A", "D"])
        collections.move(fromOffsets: [3], toOffset: 0)   // D first
        XCTAssertEqual(names(collections), ["D", "B", "C", "A"])
        collections.move(fromOffsets: [0, 2], toOffset: 4) // D and C to the end
        XCTAssertEqual(names(collections), ["B", "A", "D", "C"])
        collections.move(fromOffsets: [9], toOffset: 0)
        XCTAssertEqual(names(collections), ["B", "A", "D", "C"], "out of range is ignored")
        collections.move(fromOffsets: [1], toOffset: 99)
        XCTAssertEqual(names(collections), ["B", "D", "C", "A"])
    }

    func testMoveUpAndDownStopsAtTheEnds() {
        var collections = make(["A", "B", "C"])
        XCTAssertTrue(collections.move("c", by: -1))
        XCTAssertEqual(names(collections), ["A", "C", "B"])
        XCTAssertFalse(collections.move("a", by: -1))
        XCTAssertTrue(collections.move("a", by: 1))
        XCTAssertEqual(names(collections), ["C", "A", "B"])
        XCTAssertFalse(collections.move("b", by: 1))
        XCTAssertFalse(collections.move("missing", by: 1))
    }

    // MARK: Delete and membership

    func testDeleteRemovesOnlyTheCollection() {
        var collections = make(["To Read", "Book Club"])
        collections.add(["x", "y"], to: "to read")
        collections.add(["x"], to: "book club")
        let deleted = collections.delete("to read")
        XCTAssertEqual(deleted?.books, ["x", "y"])
        XCTAssertEqual(names(collections), ["Book Club"])
        XCTAssertEqual(collections.collection(id: "book club")?.books, ["x"], "other collections keep the book")
        XCTAssertNil(collections.delete("to read"))
    }

    func testBookInSeveralCollections() {
        var collections = make(["A", "B", "C"])
        XCTAssertEqual(collections.add(["x", "y"], to: "a"), 2)
        XCTAssertEqual(collections.add(["y", "x", "z"], to: "a"), 1, "a book already there is not added again")
        XCTAssertEqual(collections.collection(id: "a")?.books, ["x", "y", "z"], "in the order added")
        collections.add(["x"], to: "c")
        XCTAssertEqual(collections.ids(containing: "x"), ["a", "c"])
        XCTAssertEqual(collections.collections(containing: "z").map(\.name), ["A"])
        XCTAssertEqual(collections.remove(["x", "q"], from: "a"), 1)
        XCTAssertEqual(collections.ids(containing: "x"), ["c"])
        XCTAssertEqual(collections.add(["x"], to: "missing"), 0)
    }

    func testToggleAddsUntilAllAreIn() {
        var collections = make(["A"])
        collections.add(["x"], to: "a")
        XCTAssertTrue(collections.toggle(["x", "y"], in: "a"), "y is not in yet: add both")
        XCTAssertTrue(collections.containsAll(["x", "y"], in: "a"))
        XCTAssertFalse(collections.toggle(["x", "y"], in: "a"), "all in: take them out")
        XCTAssertEqual(collections.collection(id: "a")?.books, [])
        XCTAssertFalse(collections.containsAll([], in: "a"))
    }

    func testReplaceBookFollowsANewID() {
        var collections = make(["A", "B"])
        collections.add(["old", "n"], to: "a")
        collections.add(["n", "old"], to: "b")
        collections.replaceBook("old", with: "n")
        XCTAssertEqual(collections.collection(id: "a")?.books, ["n"])
        XCTAssertEqual(collections.collection(id: "b")?.books, ["n"])
        collections.add(["old"], to: "a")
        collections.replaceBook("old", with: "new")
        XCTAssertEqual(collections.collection(id: "a")?.books, ["n", "new"])
    }

    // MARK: Persistence

    func testRoundTrip() throws {
        var collections = make(["To Read", "Book Club"])
        collections.add(["x", "y"], to: "book club")
        let data = try collections.encoded()
        XCTAssertEqual(BookCollections.decode(data), collections)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, BookCollections.currentVersion)
    }

    func testMissingOrUnreadableDataIsNoCollections() {
        XCTAssertTrue(BookCollections.decode(nil).isEmpty, "no file yet")
        XCTAssertTrue(BookCollections.decode(Data()).isEmpty)
        XCTAssertTrue(BookCollections.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(BookCollections.decode(Data("{}".utf8)).isEmpty, "no collections key")
    }

    func testOlderAndPartialDataDecodeCleanly() {
        // No version, a collection without books, one without an id (skipped), a repeated id and hash, unknown keys.
        let json = """
        {"collections": [
            {"id": "1", "name": "To Read"},
            {"name": "No id", "books": ["a"]},
            {"id": "2", "name": "Club", "books": ["a", "a", "b"], "color": "red"},
            {"id": "1", "name": "Again"}
        ], "future": true}
        """
        let decoded = BookCollections.decode(Data(json.utf8))
        XCTAssertEqual(decoded.collections.map(\.id), ["1", "2"])
        XCTAssertEqual(decoded.collection(id: "1")?.books, [])
        XCTAssertEqual(decoded.collection(id: "2")?.books, ["a", "b"])
        // A bare list, and a newer version, are read too.
        let list = BookCollections.decode(Data(#"[{"id": "x", "name": "X", "books": ["h"]}]"#.utf8))
        XCTAssertEqual(list.collections.map(\.name), ["X"])
        let newer = BookCollections.decode(Data(#"{"version": 9, "collections": [{"id": "x", "name": "X"}]}"#.utf8))
        XCTAssertEqual(newer.collections.map(\.name), ["X"])
    }

    // MARK: By Collection

    func testSectionsByCollectionInTheUsersOrder() {
        let collections = [BookCollection(id: "z", name: "Zebra"), BookCollection(id: "a", name: "Alpha"),
                           BookCollection(id: "empty", name: "Empty")]
        let books = [
            LibraryBookFacts(title: "One", collectionIDs: ["a", "z"]),
            LibraryBookFacts(title: "Two", collectionIDs: ["a"]),
            LibraryBookFacts(title: "Three"),
            LibraryBookFacts(title: "Four", collectionIDs: ["deleted"]),
        ]
        let sections = LibraryBrowsing.sections(books, mode: .collections, order: .title, collections: collections,
                                                locale: en) { $0 }
        XCTAssertEqual(sections.map(\.kind), [.collection(id: "z", name: "Zebra"), .collection(id: "a", name: "Alpha"),
                                              .noCollection], "user order, empty collections left out")
        XCTAssertEqual(sections[0].items.map(\.title), ["One"])
        XCTAssertEqual(sections[1].items.map(\.title), ["One", "Two"], "in the sort order")
        XCTAssertEqual(sections[2].items.map(\.title), ["Four", "Three"], "an unknown id is no collection")
        XCTAssertEqual(sections.map(\.id), ["collection:z", "collection:a", "noCollection"])
    }

    func testByCollectionWithoutCollectionsIsOneSection() {
        let books = [LibraryBookFacts(title: "B"), LibraryBookFacts(title: "A")]
        let sections = LibraryBrowsing.sections(books, mode: .collections, order: .title, locale: en) { $0 }
        XCTAssertEqual(sections.map(\.kind), [.noCollection])
        XCTAssertEqual(sections[0].items.map(\.title), ["A", "B"])
        XCTAssertTrue(LibraryBrowsing.sections([LibraryBookFacts](), mode: .collections, order: .title) { $0 }.isEmpty)
    }
}
