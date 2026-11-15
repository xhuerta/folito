import XCTest
import ReaderCore
@testable import FolitoWatch

/// Bookmarks in the reader (#65): added at the line at the top of the screen, listed newest first, opened,
/// deleted, and kept per book next to the reading position.
@MainActor
final class BookmarkReaderTests: XCTestCase {
    private func book() -> ProcessedBook {
        let long = String(repeating: "word ", count: 40)   // 200 characters
        let chapters = [Chapter(spineIndex: 1, title: "One",
                                blocks: [Block(text: long, xpointer: "/body/DocFragment[1]/body/p", globalOffset: 0),
                                         Block(text: long, xpointer: "/body/DocFragment[1]/body/p[2]", globalOffset: 200)])]
        return ProcessedBook(metadata: BookMetadata(title: "Book", authors: []), documentHash: "marks",
                             metaHash: "", chapters: chapters, totalCharacters: 400)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "BookmarkReaderTests.\(UUID().uuidString)")!
    }

    private func reader(_ defaults: UserDefaults, now: @escaping () -> Date = { Date() }) -> ReaderViewModel {
        ReaderViewModel(book: book(), positions: PositionStore(defaults: defaults),
                        sync: SyncCoordinator(defaults: defaults, credentials: { nil }), now: now, settings: defaults)
    }

    func testAddsTheLineAtTheTopOnce() throws {
        let model = reader(defaults())
        model.jump(to: 1, characterOffset: 50)
        XCTAssertFalse(model.isCurrentPositionBookmarked)
        guard case .added(let mark)? = model.addBookmark() else { return XCTFail("the first bookmark is added") }
        XCTAssertEqual(mark.position, BookPosition(chapterIndex: 0, blockIndex: 1, characterOffset: 50))
        XCTAssertEqual(mark.xpointer, "/body/DocFragment[1]/body/p[2]/text().50")
        XCTAssertEqual(mark.percentage, 250.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(mark.chapterTitle, "One")
        XCTAssertTrue(mark.snippet.hasPrefix("word word"))
        XCTAssertTrue(model.isCurrentPositionBookmarked, "the menu now shows Bookmarked")
        XCTAssertEqual(model.addBookmark(), .duplicate(mark), "the same line is not bookmarked twice")
        XCTAssertEqual(model.bookmarks.count, 1)
        model.jump(to: 1, characterOffset: 55)
        XCTAssertFalse(model.isCurrentPositionBookmarked, "another line is another place")
    }

    func testListIsNewestFirstAndOpensTheBookmark() throws {
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let model = reader(defaults(), now: { clock })
        model.jump(to: 1, characterOffset: 50)
        model.addBookmark()
        clock += 60
        model.jump(to: 0)
        model.addBookmark()
        XCTAssertEqual(model.bookmarks.items.map(\.position.blockIndex), [0, 1])

        let older = try XCTUnwrap(model.bookmarks.items.last)
        model.jump(to: older)
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.localPercentage, 250.0 / 400, accuracy: 1e-9, "the bookmark's line, not its block's top")
        XCTAssertTrue(model.isCurrentPositionBookmarked)
    }

    func testDeleteAndPersistencePerBook() throws {
        let store = defaults()
        let model = reader(store)
        model.jump(to: 1, characterOffset: 50)
        model.addBookmark()
        model.jump(to: 0)
        model.addBookmark()
        XCTAssertEqual(reader(store).bookmarks.count, 2, "bookmarks are kept when the book is opened again")

        let first = try XCTUnwrap(model.bookmarks.items.first)
        model.deleteBookmark(id: first.id)
        XCTAssertEqual(model.bookmarks.count, 1)
        model.deleteBookmarks(atOffsets: IndexSet(integer: 0))
        XCTAssertTrue(model.bookmarks.isEmpty)
        XCTAssertTrue(reader(store).bookmarks.isEmpty, "deleting is saved")

        model.addBookmark()
        XCTAssertEqual(reader(store).bookmarks.count, 1)
        PositionStore(defaults: store).remove("marks")
        XCTAssertTrue(reader(store).bookmarks.isEmpty, "deleting the book removes its bookmarks with its position")
        reader(store).addBookmark()
        PositionStore(defaults: store).removeAll()
        XCTAssertTrue(reader(store).bookmarks.isEmpty, "Reset removes every bookmark")
    }
}
