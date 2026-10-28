import XCTest
import ReaderCore
@testable import WristReaderWatch

private func makeBook() -> ProcessedBook {
    // Chapter 0: blocks of 10, 20 chars; chapter 1: empty; chapter 2: one block of 70 chars.
    func b(_ n: Int, offset: Int) -> Block {
        Block(text: String(repeating: "x", count: n), xpointer: "/p\(offset)", globalOffset: offset)
    }
    return ProcessedBook(
        metadata: BookMetadata(title: "T", authors: ["A"]),
        documentHash: "h", metaHash: "m",
        chapters: [Chapter(spineIndex: 1, title: "One", blocks: [b(10, offset: 0), b(20, offset: 10)]),
                   Chapter(spineIndex: 2, title: nil, blocks: []),
                   Chapter(spineIndex: 3, title: nil, blocks: [b(70, offset: 30)])],
        totalCharacters: 100)
}

final class FlatBookTests: XCTestCase {
    func testFlatteningAndChapterRefs() {
        let flat = FlatBook(makeBook())
        XCTAssertEqual(flat.count, 3)
        XCTAssertEqual(flat.chapterRefs.map(\.title), ["One", "Chapter 3"])
        XCTAssertEqual(flat.chapterRefs.map(\.startIndex), [0, 2])
    }

    func testPositionRoundTripAndClamping() {
        let flat = FlatBook(makeBook())
        XCTAssertEqual(flat.flatIndex(for: BookPosition(chapterIndex: 0, blockIndex: 1)), 1)
        XCTAssertEqual(flat.flatIndex(for: BookPosition(chapterIndex: 2, blockIndex: 0)), 2)
        XCTAssertEqual(flat.flatIndex(for: BookPosition(chapterIndex: 0, blockIndex: 99)), 1)
        XCTAssertEqual(flat.flatIndex(for: BookPosition(chapterIndex: 9, blockIndex: 0)), 2)
        XCTAssertEqual(flat.position(at: 2), BookPosition(chapterIndex: 2, blockIndex: 0))
    }

    func testPercentage() {
        let flat = FlatBook(makeBook())
        XCTAssertEqual(flat.percentage(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(flat.percentage(at: 1), 0.1, accuracy: 1e-9)
        XCTAssertEqual(flat.percentage(at: 2), 0.3, accuracy: 1e-9)
    }

    func testIndexForPercentage() {
        let flat = FlatBook(makeBook())
        XCTAssertEqual(flat.index(forPercentage: 0), 0)
        XCTAssertEqual(flat.index(forPercentage: 0.09), 0)
        XCTAssertEqual(flat.index(forPercentage: 0.1), 1)
        XCTAssertEqual(flat.index(forPercentage: 0.5), 2)
        XCTAssertEqual(flat.index(forPercentage: 1.5), 2)
    }
}

final class VisibleTrackerTests: XCTestCase {
    func testTopIsMinimumVisible() {
        var t = VisibleTracker()
        XCTAssertNil(t.top)
        t.appeared(5); t.appeared(3); t.appeared(4)
        XCTAssertEqual(t.top, 3)
        t.disappeared(3)
        XCTAssertEqual(t.top, 4)
    }
}

final class BlockTextTests: XCTestCase {
    func testRunsClampAndSkipInvalid() {
        let spans = [StyleSpan(location: 0, length: 3, bold: true, italic: false),
                     StyleSpan(location: 4, length: 100, bold: false, italic: true),
                     StyleSpan(location: 50, length: 2, bold: true, italic: false),
                     StyleSpan(location: 0, length: 2, bold: false, italic: false)]
        let runs = BlockText.runs(text: "abc defg", spans: spans)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(String("abc defg"[runs[0].range]), "abc")
        XCTAssertEqual(String("abc defg"[runs[1].range]), "defg")
    }

    func testUTF16RangesWithEmoji() {
        // "a😀b": emoji is 2 UTF-16 units; bold "b" is at UTF-16 location 3.
        let text = "a😀b"
        let runs = BlockText.runs(text: text, spans: [StyleSpan(location: 3, length: 1, bold: true, italic: false)])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(String(text[runs[0].range]), "b")
    }

    func testAttributedContainsIntent() {
        let attr = BlockText.attributed(text: "ab", spans: [StyleSpan(location: 0, length: 1, bold: true, italic: true)])
        let first = attr.runs.first
        XCTAssertEqual(first?.inlinePresentationIntent, [.stronglyEmphasized, .emphasized])
    }
}

final class PendingProgressStoreTests: XCTestCase {
    private func store() -> PendingProgressStore {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return PendingProgressStore(defaults: d)
    }

    func testUpsertKeepsLatestPerDocument() {
        let s = store()
        s.upsert(KOSyncProgress(document: "a", progress: "p1", percentage: 0.1, device_id: "d", timestamp: 1))
        s.upsert(KOSyncProgress(document: "a", progress: "p2", percentage: 0.2, device_id: "d", timestamp: 2))
        s.upsert(KOSyncProgress(document: "b", progress: "p", percentage: 0.5, device_id: "d", timestamp: 3))
        XCTAssertEqual(s.all().map(\.progress), ["p2", "p"])
    }

    func testRemoveOnlyIfUnchanged() {
        let s = store()
        let old = KOSyncProgress(document: "a", progress: "p1", percentage: 0.1, device_id: "d", timestamp: 1)
        s.upsert(old)
        let newer = KOSyncProgress(document: "a", progress: "p2", percentage: 0.2, device_id: "d", timestamp: 2)
        s.upsert(newer)
        s.remove(old)
        XCTAssertEqual(s.all(), [newer])
        s.remove(newer)
        XCTAssertTrue(s.isEmpty)
    }
}

final class MiscLogicTests: XCTestCase {
    func testFontSizeClamp() {
        XCTAssertEqual(ReaderSettings.clampFontSize(2), ReaderSettings.minFontSize)
        XCTAssertEqual(ReaderSettings.clampFontSize(99), ReaderSettings.maxFontSize)
        XCTAssertEqual(ReaderSettings.clampFontSize(.nan), ReaderSettings.defaultFontSize)
    }

    func testServerURLParsing() {
        XCTAssertEqual(ServerURL.parse("sync.example.org")?.absoluteString, "https://sync.example.org")
        XCTAssertEqual(ServerURL.parse("http://10.0.0.2:8080")?.port, 8080)
        XCTAssertNil(ServerURL.parse("   "))
        XCTAssertNil(ServerURL.credentials(server: "x.org", user: "u", password: nil))
        XCTAssertEqual(ServerURL.credentials(server: "", user: "u", password: "p")?.username, "u")
    }

    func testErrorClassification() {
        XCTAssertEqual(SyncErrorClassifier.status(for: KOSyncError.offline), .offline)
        XCTAssertEqual(SyncErrorClassifier.status(for: KOSyncError.unauthorized), .error)
        XCTAssertEqual(SyncErrorClassifier.status(for: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(SyncErrorClassifier.status(for: URLError(.badServerResponse)), .error)
    }

    func testPermanentRejection() {
        XCTAssertTrue(SyncErrorClassifier.isPermanentRejection(KOSyncError.server(status: 403)))
        XCTAssertFalse(SyncErrorClassifier.isPermanentRejection(KOSyncError.server(status: 429)))
        XCTAssertFalse(SyncErrorClassifier.isPermanentRejection(KOSyncError.server(status: 502)))
        XCTAssertFalse(SyncErrorClassifier.isPermanentRejection(KOSyncError.unauthorized))
        XCTAssertFalse(SyncErrorClassifier.isPermanentRejection(KOSyncError.offline))
    }

    func testDeleteMessageSchema() {
        // Shape sent by the iPhone (WatchSchema.deleteBook) and the legacy shape.
        XCTAssertEqual(ConnectivityReceiver.deleteHash(from: ["type": "delete_book", "documentHash": "abc"]), "abc")
        XCTAssertEqual(ConnectivityReceiver.deleteHash(from: ["delete_book": "abc"]), "abc")
        XCTAssertNil(ConnectivityReceiver.deleteHash(from: ["type": "settings", "documentHash": "abc"]))
        XCTAssertNil(ConnectivityReceiver.deleteHash(from: ["type": "delete_book"]))
    }

    func testSafeName() {
        XCTAssertEqual(BookStorage.safeName("ab12/../x"), "ab12____x")
    }

    func testBookCompressionRoundTrip() throws {
        let book = makeBook()
        let json = try JSONEncoder().encode(book)
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data
        XCTAssertEqual(try BookStorage.decode(compressed: compressed), book)
    }
}
