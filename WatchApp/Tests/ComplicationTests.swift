import XCTest
import ReaderCore
@testable import FolitoWatch

final class ReadingSnapshotTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let s = ReadingSnapshot(bookID: "abc123", title: "Emma", chapterTitle: "Volume I", fraction: 0.4567,
                                minutesLeft: 12, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try XCTUnwrap(s.encoded())
        XCTAssertEqual(ReadingSnapshot.decode(data), s)
        // Optional fields survive as nil.
        let bare = ReadingSnapshot(bookID: "x", title: "T", chapterTitle: nil, fraction: 0,
                                   updatedAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(ReadingSnapshot.decode(try XCTUnwrap(bare.encoded())), bare)
        XCTAssertNil(bare.minutesLeft)
    }

    func testDecodeRejectsGarbageAndUnknownVersions() {
        XCTAssertNil(ReadingSnapshot.decode(Data("not json".utf8)))
        let future = #"{"version":99,"bookID":"a","title":"T","fraction":0.5,"updatedAt":0}"#
        XCTAssertNil(ReadingSnapshot.decode(Data(future.utf8)))
        let emptyID = #"{"version":1,"bookID":"","title":"T","fraction":0.5,"updatedAt":0}"#
        XCTAssertNil(ReadingSnapshot.decode(Data(emptyID.utf8)))
        let minimal = #"{"version":1,"bookID":"a","title":"T","fraction":0.5,"updatedAt":0}"#
        XCTAssertEqual(ReadingSnapshot.decode(Data(minimal.utf8))?.chapterTitle, nil)
    }

    func testClampingAndWholePercent() {
        XCTAssertEqual(ReadingSnapshot(bookID: "a", title: "", chapterTitle: nil, fraction: 1.7).fraction, 1)
        XCTAssertEqual(ReadingSnapshot(bookID: "a", title: "", chapterTitle: nil, fraction: .nan).fraction, 0)
        XCTAssertEqual(ReadingSnapshot(bookID: "a", title: "", chapterTitle: nil, fraction: 0.29).wholePercent, 29)
        XCTAssertEqual(ReadingSnapshot(bookID: "a", title: "", chapterTitle: nil, fraction: 0.999).wholePercent, 99)
        XCTAssertEqual(ReadingSnapshot(bookID: "a", title: "", chapterTitle: nil, fraction: 0.5, minutesLeft: -3).minutesLeft, 0)
    }

    func testDiffersVisiblyIgnoresSubPercentMoves() {
        let a = ReadingSnapshot(bookID: "a", title: "T", chapterTitle: "C", fraction: 0.451)
        XCTAssertFalse(ReadingSnapshot(bookID: "a", title: "T", chapterTitle: "C", fraction: 0.459).differsVisibly(from: a))
        XCTAssertTrue(ReadingSnapshot(bookID: "a", title: "T", chapterTitle: "C", fraction: 0.46).differsVisibly(from: a))
        XCTAssertTrue(ReadingSnapshot(bookID: "a", title: "T", chapterTitle: "D", fraction: 0.451).differsVisibly(from: a))
        XCTAssertTrue(a.differsVisibly(from: nil))
    }

    func testStoreSaveLoadClear() {
        let defaults = UserDefaults(suiteName: "ComplicationTests.\(UUID().uuidString)")!
        let store = ReadingSnapshotStore(defaults: defaults)
        XCTAssertNil(store.load())
        let s = ReadingSnapshot(bookID: "a", title: "T", chapterTitle: nil, fraction: 0.2,
                                updatedAt: Date(timeIntervalSince1970: 10))
        store.save(s)
        XCTAssertEqual(store.load(), s)
        store.clear()
        XCTAssertNil(store.load())
        // No App Group: a store that does nothing.
        let none = ReadingSnapshotStore(defaults: nil)
        none.save(s)
        XCTAssertNil(none.load())
    }

    @MainActor
    func testPublisherReloadsOnlyOnVisibleChangesOrForce() {
        let store = ReadingSnapshotStore(defaults: UserDefaults(suiteName: "ComplicationTests.\(UUID().uuidString)")!)
        var reloads = 0
        let publisher = ComplicationPublisher(store: store, reload: { reloads += 1 })
        publisher.publish(ReadingSnapshot(bookID: "a", title: "T", chapterTitle: nil, fraction: 0.101))
        publisher.publish(ReadingSnapshot(bookID: "a", title: "T", chapterTitle: nil, fraction: 0.105))
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(store.load()?.fraction ?? 0, 0.105, accuracy: 1e-9, "the store always has the latest position")
        publisher.publish(ReadingSnapshot(bookID: "a", title: "T", chapterTitle: nil, fraction: 0.106), force: true)
        XCTAssertEqual(reloads, 2)
        publisher.bookRemoved("other")
        XCTAssertNotNil(store.load())
        publisher.bookRemoved("a")
        XCTAssertNil(store.load())
        XCTAssertEqual(reloads, 3)
    }

    @MainActor
    func testReaderSnapshotHasChapterAndMinutesLeft() async throws {
        let chapters = [Chapter(spineIndex: 1, title: "One",
                                blocks: [Block(text: String(repeating: "x", count: 50), xpointer: "/a", globalOffset: 0)]),
                        Chapter(spineIndex: 2, title: "Two",
                                blocks: [Block(text: String(repeating: "y", count: 50), xpointer: "/b", globalOffset: 50)])]
        let book = ProcessedBook(metadata: BookMetadata(title: "Book", authors: []), documentHash: "hash1",
                                 metaHash: "", chapters: chapters, totalCharacters: 100)
        let defaults = UserDefaults(suiteName: "ComplicationTests.\(UUID().uuidString)")!
        let store = ReadingSnapshotStore(defaults: defaults)
        let model = ReaderViewModel(book: book, positions: PositionStore(defaults: defaults),
                                    sync: SyncCoordinator(defaults: defaults, credentials: { nil }),
                                    complications: ComplicationPublisher(store: store, reload: {}),
                                    settings: defaults)
        model.jump(to: 1)
        let s = model.complicationSnapshot
        XCTAssertEqual(s.bookID, "hash1")
        XCTAssertEqual(s.title, "Book")
        XCTAssertEqual(s.chapterTitle, "Two")
        XCTAssertEqual(s.fraction, 0.5, accuracy: 1e-9)
        // Words are counted off the main actor; once they are, the published snapshot has the estimate.
        for _ in 0..<100 where model.timeRemaining == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(model.timeRemaining)
        XCTAssertEqual(model.minutesLeftInChapter(), 1, "a one-word chapter still shows at least 1 minute")
        XCTAssertEqual(store.load()?.minutesLeft, 1, "the snapshot is published again after the estimate is ready")
        defaults.set(false, forKey: ReaderSettings.showTimeRemainingKey)
        XCTAssertNil(model.minutesLeftInChapter(), "Show Time Remaining off hides minutes left")
        XCTAssertNil(model.complicationSnapshot.minutesLeft)
    }
}

final class FolitoDeepLinkTests: XCTestCase {
    func testRoundTrip() {
        for link in [FolitoDeepLink.library, .book(id: "0a1b2c3d4e5f"), .book(id: "meta_hash-1")] {
            XCTAssertEqual(FolitoDeepLink(url: link.url), link)
        }
        XCTAssertEqual(FolitoDeepLink.book(id: "abc").url.absoluteString, "folito://book/abc")
        XCTAssertEqual(FolitoDeepLink.library.url.absoluteString, "folito://library")
    }

    func testParsing() {
        XCTAssertEqual(FolitoDeepLink(url: URL(string: "FOLITO://Library")!), .library)
        XCTAssertEqual(FolitoDeepLink(url: URL(string: "folito://book/abc/")!), .book(id: "abc"))
        XCTAssertNil(FolitoDeepLink(url: URL(string: "https://library")!))
        XCTAssertNil(FolitoDeepLink(url: URL(string: "folito://settings")!))
        XCTAssertNil(FolitoDeepLink(url: URL(string: "folito://book")!))
        XCTAssertNil(FolitoDeepLink(url: URL(string: "folito://book/a/b")!))
        XCTAssertNil(FolitoDeepLink(url: URL(string: "folito://book/%2E%2E")!))
        XCTAssertNil(FolitoDeepLink(url: URL(string: "folito://book/" + String(repeating: "a", count: 129))!))
        XCTAssertNil(FolitoDeepLink(url: URL(string: "folito://library/extra")!))
    }

    func testLinkForSnapshot() {
        XCTAssertEqual(FolitoDeepLink.forSnapshot(nil), .library)
        XCTAssertEqual(FolitoDeepLink.forSnapshot(ReadingSnapshot(bookID: "h", title: "T", chapterTitle: nil, fraction: 0)),
                       .book(id: "h"))
        XCTAssertEqual(FolitoDeepLink.forSnapshot(ReadingSnapshot(bookID: "a b", title: "T", chapterTitle: nil, fraction: 0)),
                       .library)
    }
}

final class ComplicationTextTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    func testShortTitle() {
        XCTAssertEqual(ComplicationText.shortTitle("Dune: Book One"), "Dune")
        XCTAssertEqual(ComplicationText.shortTitle("Emma \u{2014} A Novel"), "Emma")
        XCTAssertEqual(ComplicationText.shortTitle("  Moby   Dick  "), "Moby Dick")
        // A head that is too short to be a title keeps the full title.
        XCTAssertEqual(ComplicationText.shortTitle("It: A Novel"), "It: A Novel")
    }

    func testInlineAndAccessibility() {
        let s = ReadingSnapshot(bookID: "a", title: "Emma", chapterTitle: nil, fraction: 0.45)
        XCTAssertEqual(ComplicationText.inline(s, locale: en), "45% \u{00B7} Emma")
        XCTAssertEqual(ComplicationText.inline(s, title: "", locale: en), "45%")
        XCTAssertEqual(ComplicationText.accessibilityLabel(s, redacted: false, locale: en), "Folito, 45% of Emma")
        XCTAssertEqual(ComplicationText.accessibilityLabel(s, redacted: true, locale: en), "Folito, 45%")
        XCTAssertEqual(ComplicationText.accessibilityLabel(nil, redacted: false, locale: en), "Folito, start reading")
    }

    func testRelevanceEntries() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(SmartStackRelevance.entries(for: nil, now: now).count, 1)
        let recent = ReadingSnapshot(bookID: "a", title: "T", chapterTitle: nil, fraction: 0.1, updatedAt: now)
        let points = SmartStackRelevance.entries(for: recent, now: now)
        XCTAssertEqual(points.map(\.date), [now, now.addingTimeInterval(SmartStackRelevance.recentWindow)])
        XCTAssertEqual(points.first?.relevance?.score, SmartStackRelevance.recentScore)
        let old = ReadingSnapshot(bookID: "a", title: "T", chapterTitle: nil, fraction: 0.1,
                                  updatedAt: now.addingTimeInterval(-2 * SmartStackRelevance.recentWindow))
        XCTAssertEqual(SmartStackRelevance.entries(for: old, now: now).map(\.relevance?.score), [SmartStackRelevance.idleScore])
    }
}
