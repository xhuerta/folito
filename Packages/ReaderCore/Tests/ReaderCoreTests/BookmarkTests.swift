import XCTest
@testable import ReaderCore

/// Bookmarks on the watch (#65): the per-book list, its persistence and where a bookmark lands in a book.
final class BookmarkTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// One chapter (spine item 1) with the given (text, XPointer path below `<body>`) blocks.
    private func book(_ blocks: [(String, String)], hash: String = "doc") -> ProcessedBook {
        var offset = 0
        var built: [Block] = []
        for (text, path) in blocks {
            built.append(Block(text: text, xpointer: "/body/DocFragment[1]/body/\(path)", globalOffset: offset))
            offset += text.count
        }
        return ProcessedBook(metadata: BookMetadata(title: "Alice", authors: []), documentHash: hash, metaHash: "",
                             chapters: [Chapter(spineIndex: 1, title: "Down the Rabbit-Hole", blocks: built)],
                             totalCharacters: offset)
    }

    private var alice: ProcessedBook {
        book([("Chapter One", "h1"),
              ("Alice was beginning to get very tired.", "p"),
              ("So she was considering in her own mind.", "p[2]")])
    }

    private func mark(_ block: Int, _ offset: Int = 0, at seconds: TimeInterval = 0, id: UUID = UUID()) -> Bookmark {
        Bookmark(id: id, position: BookPosition(chapterIndex: 0, blockIndex: block, characterOffset: offset),
                 percentage: Double(block) / 10, chapterTitle: "One", snippet: "s\(block)",
                 createdAt: t0.addingTimeInterval(seconds))
    }

    // MARK: Snippet

    func testSnippetStartsAtTheWordAndCollapsesWhitespace() {
        let text = "The quick brown fox jumps over the lazy dog."
        XCTAssertEqual(Bookmark.snippet(from: text, at: 0), text)
        XCTAssertEqual(Bookmark.snippet(from: text, at: 6), "quick brown fox jumps over the lazy dog.",
                       "an offset inside a word starts at that word")
        XCTAssertEqual(Bookmark.snippet(from: text, at: 4), "quick brown fox jumps over the lazy dog.")
        XCTAssertEqual(Bookmark.snippet(from: "  one\n\n two\tthree  ", at: 0), "one two three")
        XCTAssertEqual(Bookmark.snippet(from: text, at: 999), text, "at the end of the block: its opening words")
        XCTAssertEqual(Bookmark.snippet(from: text, at: -3), text)
        XCTAssertEqual(Bookmark.snippet(from: "", at: 0), "")
        XCTAssertEqual(Bookmark.snippet(from: "Él leyó «Cien años» ayer.", at: 5), "leyó «Cien años» ayer.")
        XCTAssertEqual(Bookmark.snippet(from: "吾輩は猫である。名前はまだ無い。", at: 8), "名前はまだ無い。",
                       "text without spaces starts at the offset, not at the block's start")
    }

    func testSnippetIsCutAfterAWholeWord() {
        XCTAssertEqual(Bookmark.snippet(from: "quick brown fox jumps", at: 0, maxLength: 15), "quick brown fox…")
        XCTAssertEqual(Bookmark.snippet(from: "quick brown fox jumps", at: 0, maxLength: 14), "quick brown…")
        XCTAssertEqual(Bookmark.snippet(from: "Supercalifragilistic word", at: 0, maxLength: 5), "Super…",
                       "a single long word is still shortened")
        XCTAssertEqual(Bookmark.snippet(from: "吾輩は猫である。名前はまだ無い。", at: 0, maxLength: 5), "吾輩は猫で…")
        let long = String(repeating: "word ", count: 40)
        XCTAssertLessThanOrEqual(Bookmark.snippet(from: long, at: 0).count, Bookmark.snippetLength + 1)
    }

    // MARK: Making a bookmark

    func testMakeTakesXPointerPercentageAndSnippetFromTheBook() throws {
        let b = try XCTUnwrap(Bookmark.make(at: BookPosition(chapterIndex: 0, blockIndex: 2, characterOffset: 7),
                                            in: alice, chapterTitle: "  Down the Rabbit-Hole ", createdAt: t0))
        XCTAssertEqual(b.position, BookPosition(chapterIndex: 0, blockIndex: 2, characterOffset: 7))
        XCTAssertEqual(b.xpointer, "/body/DocFragment[1]/body/p[2]/text().7")
        XCTAssertEqual(b.percentage, Double(11 + 38 + 7) / Double(alice.totalCharacters), accuracy: 1e-9)
        XCTAssertEqual(b.chapterTitle, "Down the Rabbit-Hole")
        XCTAssertEqual(b.snippet, "was considering in her own mind.")
        XCTAssertEqual(b.createdAt, t0)

        let clamped = try XCTUnwrap(Bookmark.make(at: BookPosition(chapterIndex: 0, blockIndex: 0, characterOffset: 500),
                                                  in: alice, chapterTitle: "", createdAt: t0))
        XCTAssertEqual(clamped.position.characterOffset, 11)
        XCTAssertNil(clamped.chapterTitle, "an empty title is no title")
        XCTAssertNil(Bookmark.make(at: BookPosition(chapterIndex: 3, blockIndex: 0), in: alice, chapterTitle: nil, createdAt: t0))
        XCTAssertNil(Bookmark.make(at: BookPosition(chapterIndex: 0, blockIndex: 9), in: alice, chapterTitle: nil, createdAt: t0))
    }

    // MARK: List

    func testNewestFirst() {
        var list = BookmarkList()
        list.add(mark(1, at: 10))
        list.add(mark(5, at: 30))
        list.add(mark(3, at: 20))
        XCTAssertEqual(list.items.map(\.position.blockIndex), [5, 3, 1])
        // Same clock tick: further into the book first.
        list.add(mark(2, at: 30))
        XCTAssertEqual(list.items.map(\.position.blockIndex), [5, 2, 3, 1])
        // The initializer sorts too.
        XCTAssertEqual(BookmarkList([mark(1, at: 1), mark(2, at: 2)]).items.map(\.position.blockIndex), [2, 1])
    }

    func testOneBookmarkPerPosition() {
        var list = BookmarkList()
        let first = mark(2, 7, at: 0)
        XCTAssertEqual(list.add(first), .added(first))
        XCTAssertEqual(list.add(mark(2, 7, at: 60)), .duplicate(first), "the same position is not bookmarked twice")
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list.contains(first.position))
        XCTAssertEqual(list.bookmark(at: first.position), first)
        // Another line of the same block is another place.
        if case .duplicate = list.add(mark(2, 8, at: 60)) { XCTFail("a different offset is a new bookmark") }
        XCTAssertEqual(list.count, 2)
        // Duplicates in stored data collapse to the newest.
        let id = UUID()
        let decoded = BookmarkList([mark(1, at: 5), mark(1, at: 9, id: id), mark(4, at: 1, id: id)])
        XCTAssertEqual(decoded.items.map(\.position.blockIndex), [1])
        XCTAssertEqual(decoded.items.first?.id, id)
    }

    func testDelete() {
        let a = mark(1, at: 1), b = mark(2, at: 2), c = mark(3, at: 3)
        var list = BookmarkList([a, b, c])
        XCTAssertTrue(list.remove(id: b.id))
        XCTAssertFalse(list.remove(id: b.id))
        XCTAssertEqual(list.items, [c, a])
        list.remove(atOffsets: IndexSet([0, 7]))
        XCTAssertEqual(list.items, [a], "swipe to delete removes the row at that offset; others are ignored")
        list.remove(atOffsets: IndexSet(integer: 0))
        XCTAssertTrue(list.isEmpty)
        // A deleted position can be bookmarked again.
        XCTAssertEqual(list.add(b), .added(b))
    }

    // MARK: Persistence

    func testEncodeDecodeRoundTrip() throws {
        let list = BookmarkList([try XCTUnwrap(Bookmark.make(at: BookPosition(chapterIndex: 0, blockIndex: 1, characterOffset: 6),
                                                             in: alice, chapterTitle: "One", createdAt: t0)),
                                 mark(2, at: 5)])
        let data = try JSONEncoder().encode(list)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, BookmarkList.formatVersion)
        XCTAssertEqual(try JSONDecoder().decode(BookmarkList.self, from: data), list)
    }

    func testDecodingIsLenient() throws {
        let id = UUID().uuidString
        let json = """
        {"version": 9, "future": true, "bookmarks": [
          {"id": "\(id)", "position": {"chapterIndex": 0, "blockIndex": 2}, "percentage": 7, "extra": 1},
          {"id": "not-a-uuid", "position": {"chapterIndex": 0, "blockIndex": 1}},
          {"position": {"chapterIndex": 0, "blockIndex": 3}}
        ]}
        """
        let list = try JSONDecoder().decode(BookmarkList.self, from: Data(json.utf8))
        XCTAssertEqual(list.count, 1, "entries that cannot be read are skipped, the rest kept")
        let b = try XCTUnwrap(list.items.first)
        XCTAssertEqual(b.id.uuidString, id)
        XCTAssertEqual(b.position, BookPosition(chapterIndex: 0, blockIndex: 2, characterOffset: 0))
        XCTAssertEqual(b.percentage, 1, "percentages are clamped to 0...1")
        XCTAssertNil(b.xpointer)
        XCTAssertNil(b.chapterTitle)
        XCTAssertEqual(b.snippet, "")
        XCTAssertTrue(try JSONDecoder().decode(BookmarkList.self, from: Data("{}".utf8)).isEmpty)
    }

    func testStoreKeepsBookmarksPerBook() {
        let name = "BookmarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BookmarkStore(defaults: defaults)
        XCTAssertTrue(store.load(documentHash: "a").isEmpty)

        let a1 = mark(1, at: 1), a2 = mark(2, at: 2), b1 = mark(1, at: 3)
        XCTAssertEqual(store.add(a1, documentHash: "a"), .added(a1))
        XCTAssertEqual(store.add(a2, documentHash: "a"), .added(a2))
        XCTAssertEqual(store.add(mark(1, at: 9), documentHash: "a"), .duplicate(a1))
        store.add(b1, documentHash: "b")

        // A new store on the same defaults (the app relaunched) reads the same lists.
        let reopened = BookmarkStore(defaults: defaults)
        XCTAssertEqual(reopened.load(documentHash: "a").items, [a2, a1])
        XCTAssertEqual(reopened.load(documentHash: "b").items, [b1])

        XCTAssertEqual(reopened.remove(id: a2.id, documentHash: "a").items, [a1])
        XCTAssertEqual(store.load(documentHash: "a").items, [a1])
        store.remove(id: a1.id, documentHash: "a")
        XCTAssertNil(store.all()["a"], "an empty list leaves no entry behind")
        XCTAssertEqual(Set(store.all().keys), ["b"])

        store.add(a1, documentHash: "a")
        store.remove(documentHash: "b")
        XCTAssertTrue(store.load(documentHash: "b").isEmpty)
        XCTAssertEqual(store.load(documentHash: "a").count, 1, "deleting one book keeps the others' bookmarks")
        defaults.set(1, forKey: "position.a")
        store.removeAll()
        XCTAssertTrue(store.load(documentHash: "a").isEmpty)
        XCTAssertEqual(defaults.integer(forKey: "position.a"), 1, "Reset of bookmarks touches nothing else")

        defaults.set(Data("garbage".utf8), forKey: BookmarkStore.key)
        XCTAssertTrue(store.load(documentHash: "a").isEmpty, "unreadable data reads as no bookmarks")
        XCTAssertEqual(store.add(a1, documentHash: "a"), .added(a1), "and is replaced by the next save")
        XCTAssertEqual(store.load(documentHash: "a").items, [a1])
    }

    // MARK: Where a bookmark lands

    func testSameBookResolvesToTheMarkedPosition() throws {
        let b = try XCTUnwrap(Bookmark.make(at: BookPosition(chapterIndex: 0, blockIndex: 2, characterOffset: 7),
                                            in: alice, chapterTitle: nil, createdAt: t0))
        XCTAssertEqual(b.resolvedPosition(in: alice), BookPosition(chapterIndex: 0, blockIndex: 2, characterOffset: 7))
    }

    /// The iPhone sends the book again (same document hash) and it is processed into other blocks (here an
    /// illustration before the text): the bookmark still lands on the marked line.
    func testBookmarkSurvivesTheBookBeingSentAgain() throws {
        let b = try XCTUnwrap(Bookmark.make(at: BookPosition(chapterIndex: 0, blockIndex: 2, characterOffset: 7),
                                            in: alice, chapterTitle: nil, createdAt: t0))
        let name = "BookmarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        BookmarkStore(defaults: defaults).add(b, documentHash: alice.documentHash)

        let resent = book([("[Illustration]", "div"),
                           ("Chapter One", "h1"),
                           ("Alice was beginning to get very tired.", "p"),
                           ("So she was considering in her own mind.", "p[2]")])
        XCTAssertEqual(resent.documentHash, alice.documentHash)
        let stored = try XCTUnwrap(BookmarkStore(defaults: defaults).load(documentHash: resent.documentHash).items.first)
        XCTAssertEqual(stored.resolvedPosition(in: resent), BookPosition(chapterIndex: 0, blockIndex: 3, characterOffset: 7))
    }

    func testWithoutAMatchingXPointerTheStoredPositionOrNothing() {
        var b = mark(1, 4)
        XCTAssertEqual(b.resolvedPosition(in: alice), BookPosition(chapterIndex: 0, blockIndex: 1, characterOffset: 4))
        b.xpointer = "/body/DocFragment[7]/body/p"
        XCTAssertEqual(b.resolvedPosition(in: alice), BookPosition(chapterIndex: 0, blockIndex: 1, characterOffset: 4),
                       "an XPointer into another spine item falls back to the stored position")
        b.position = BookPosition(chapterIndex: 0, blockIndex: 1, characterOffset: 900)
        XCTAssertEqual(b.resolvedPosition(in: alice)?.characterOffset, 38, "the offset is clamped to the block")
        b.position = BookPosition(chapterIndex: 0, blockIndex: 40)
        XCTAssertNil(b.resolvedPosition(in: alice), "no such block: the caller uses the percentage")
    }
}
