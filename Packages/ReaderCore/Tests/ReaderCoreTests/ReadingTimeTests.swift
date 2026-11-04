import XCTest
@testable import ReaderCore

final class ReadingTimeTests: XCTestCase {
    // MARK: Counting

    func testCountsSpaceSeparatedWords() {
        XCTAssertEqual(TextLength("The quick brown fox.").words, 4)
        XCTAssertEqual(TextLength("  don't  stop—well-known 3.5 … ").words, 3)
        XCTAssertEqual(TextLength("Él leyó «Cien años» ayer.").words, 5)
        XCTAssertEqual(TextLength("").words, 0)
        XCTAssertEqual(TextLength(" — … ").words, 0)
        XCTAssertEqual(TextLength("one\ntwo\tthree").words, 3)
    }

    func testCountsCJKByCharacter() {
        let ja = TextLength("吾輩は猫である。名前はまだ無い。")
        XCTAssertEqual(ja.words, 0)
        XCTAssertEqual(ja.cjkCharacters, 14) // punctuation 。 is not counted
        let zh = TextLength("我们读书。")
        XCTAssertEqual(zh, TextLength(words: 0, cjkCharacters: 4))
        let mixed = TextLength("Swift言語 is fun")
        XCTAssertEqual(mixed, TextLength(words: 3, cjkCharacters: 2))
        // Korean separates words with spaces.
        XCTAssertEqual(TextLength("나는 책을 읽는다"), TextLength(words: 3, cjkCharacters: 0))
    }

    // MARK: Speed

    func testDefaultEstimate() {
        let s = ReadingSpeed.default
        XCTAssertEqual(s.seconds(for: TextLength(words: 200, cjkCharacters: 0)), 60, accuracy: 0.001)
        XCTAssertEqual(s.seconds(for: TextLength(words: 0, cjkCharacters: 500)), 60, accuracy: 0.001)
        XCTAssertEqual(s.seconds(for: TextLength(words: 100, cjkCharacters: 250)), 60, accuracy: 0.001)
    }

    func testSpeedIsClamped() {
        XCTAssertEqual(ReadingSpeed(wordsPerMinute: 1e9, charactersPerMinute: -4).wordsPerMinute, 1_000)
        XCTAssertEqual(ReadingSpeed(wordsPerMinute: .nan, charactersPerMinute: 1).wordsPerMinute, 200)
        XCTAssertEqual(ReadingSpeed(wordsPerMinute: 200, charactersPerMinute: 1).charactersPerMinute, 100)
    }

    func testLearnerMovesTowardsObservedSpeed() throws {
        let learner = ReadingSpeedLearner(smoothing: 0.5)
        // 100 words in 20 s = 300 wpm; halfway from 200 = 250.
        let s = try XCTUnwrap(learner.updated(.default, page: TextLength(words: 100, cjkCharacters: 0), seconds: 20))
        XCTAssertEqual(s.wordsPerMinute, 250, accuracy: 0.001)
        XCTAssertEqual(s.charactersPerMinute, 500)
        // A CJK page updates only the characters-per-minute speed.
        let c = try XCTUnwrap(learner.updated(.default, page: TextLength(words: 0, cjkCharacters: 300), seconds: 60))
        XCTAssertEqual(c.charactersPerMinute, 400, accuracy: 0.001)
        XCTAssertEqual(c.wordsPerMinute, 200)
    }

    func testLearnerConvergesWithEMA() {
        var s = ReadingSpeed.default
        for _ in 0..<60 {
            s = ReadingSpeedLearner.standard.updated(s, page: TextLength(words: 60, cjkCharacters: 0), seconds: 30) ?? s
        }
        XCTAssertEqual(s.wordsPerMinute, 120, accuracy: 1)
    }

    func testLearnerIgnoresOutliers() {
        let l = ReadingSpeedLearner.standard
        let page = TextLength(words: 60, cjkCharacters: 0)
        XCTAssertNil(l.updated(.default, page: page, seconds: 1.5), "skimmed page")
        XCTAssertNil(l.updated(.default, page: page, seconds: 301), "pause")
        XCTAssertNil(l.updated(.default, page: page, seconds: .infinity))
        XCTAssertNil(l.updated(.default, page: .zero, seconds: 30))
        XCTAssertNil(l.updated(.default, page: TextLength(words: 2_000, cjkCharacters: 0), seconds: 4), "crown fling")
        XCTAssertNil(l.updated(.default, page: TextLength(words: 60, cjkCharacters: 0), seconds: 240), "unread page")
        XCTAssertNotNil(l.updated(.default, page: page, seconds: 4))
        XCTAssertNotNil(l.updated(.default, page: TextLength(words: 300, cjkCharacters: 0), seconds: 300))
    }

    func testPageTimerGroupsBlocksIntoPages() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var timer = PageTimer(start: t0)
        XCTAssertNil(timer.advance(by: TextLength(words: 20, cjkCharacters: 0), at: t0 + 5))
        XCTAssertNil(timer.advance(by: TextLength(words: 20, cjkCharacters: 0), at: t0 + 10))
        let page = timer.advance(by: TextLength(words: 20, cjkCharacters: 0), at: t0 + 18)
        XCTAssertEqual(page?.length, TextLength(words: 60, cjkCharacters: 0))
        XCTAssertEqual(page?.seconds, 18)
        XCTAssertEqual(timer.accumulated, .zero)
        XCTAssertEqual(timer.pageStart, t0 + 18)
        // A fast scroll past 300 words is one skimmed page: no speed update.
        XCTAssertNil(timer.advance(by: TextLength(words: 300, cjkCharacters: 0), at: t0 + 19, speed: .default))
        // A reset drops what was accumulated.
        _ = timer.advance(by: TextLength(words: 30, cjkCharacters: 0), at: t0 + 30)
        timer.reset(at: t0 + 40)
        XCTAssertEqual(timer.accumulated, .zero)
        // CJK pages: 125 characters = 50 word equivalents.
        XCTAssertNotNil(timer.advance(by: TextLength(words: 0, cjkCharacters: 125), at: t0 + 55, speed: .default))
    }

    func testSpeedStoreRoundTripStaysOnDevice() {
        let name = "ReadingTimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReadingSpeedStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default)
        store.save(ReadingSpeed(wordsPerMinute: 321, charactersPerMinute: 654))
        XCTAssertEqual(ReadingSpeedStore(defaults: defaults).load(),
                       ReadingSpeed(wordsPerMinute: 321, charactersPerMinute: 654))
        store.reset()
        XCTAssertEqual(store.load(), .default)
        defaults.set(Data("garbage".utf8), forKey: ReadingSpeedStore.key)
        XCTAssertEqual(store.load(), .default)
    }

    // MARK: Index and estimate

    private func sampleIndex() -> BookLengthIndex {
        // Chapter 0: 2 blocks of 100 words; chapter 1: 1 block of 200 words and 1 of 250 CJK characters.
        let w100 = Array(repeating: "word", count: 100).joined(separator: " ")
        let w200 = Array(repeating: "word", count: 200).joined(separator: " ")
        let cjk = String(repeating: "読", count: 250)
        return BookLengthIndex(blockTexts: [w100, w100, w200, cjk], chapterOfBlock: [0, 0, 1, 1])
    }

    func testRemainingByChapterAndBook() {
        let index = sampleIndex()
        XCTAssertEqual(index.blockCount, 4)
        XCTAssertEqual(index.total, TextLength(words: 400, cjkCharacters: 250))
        let r0 = index.remaining(fromBlock: 0)
        XCTAssertEqual(r0.chapter, TextLength(words: 200, cjkCharacters: 0))
        XCTAssertEqual(r0.book, TextLength(words: 400, cjkCharacters: 250))
        let r1 = index.remaining(fromBlock: 1)
        XCTAssertEqual(r1.chapter, TextLength(words: 100, cjkCharacters: 0))
        let r3 = index.remaining(fromBlock: 3)
        XCTAssertEqual(r3.chapter, TextLength(words: 0, cjkCharacters: 250))
        XCTAssertEqual(r3.book, r3.chapter)
        // Out of range is clamped.
        XCTAssertEqual(index.remaining(fromBlock: 99).book, r3.book)
        XCTAssertEqual(index.length(from: 1, to: 3), TextLength(words: 300, cjkCharacters: 0))
        XCTAssertEqual(index.length(from: 3, to: 1), .zero)
        let empty = BookLengthIndex(blockTexts: [], chapterOfBlock: [])
        XCTAssertEqual(empty.remaining(fromBlock: 0).book, .zero)
    }

    func testEstimate() {
        let e = ReadingTimeEstimator.estimate(sampleIndex(), atBlock: 0, speed: .default)
        XCTAssertEqual(e.chapter, 60, accuracy: 0.001)
        XCTAssertEqual(e.book, 150, accuracy: 0.001) // 400 words at 200 wpm + 250 characters at 500 cpm
    }

    func testIndexFromProcessedBookMatchesReadingOrder() {
        func block(_ t: String) -> Block { Block(text: t, xpointer: "", globalOffset: 0) }
        let book = ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "",
                                 chapters: [Chapter(spineIndex: 1, title: nil, blocks: [block("a b"), block("c")]),
                                            Chapter(spineIndex: 2, title: nil, blocks: []),
                                            Chapter(spineIndex: 3, title: nil, blocks: [block("d e f")])],
                                 totalCharacters: 0)
        let index = BookLengthIndex(book: book)
        XCTAssertEqual(index.remaining(fromBlock: 0).chapter.words, 3)
        XCTAssertEqual(index.remaining(fromBlock: 2).chapter.words, 3)
        XCTAssertEqual(index.total.words, 6)
    }

    func testDisplayMinutes() {
        XCTAssertEqual(ReadingTimeEstimator.displayMinutes(0), 0)
        XCTAssertEqual(ReadingTimeEstimator.displayMinutes(-3), 0)
        XCTAssertEqual(ReadingTimeEstimator.displayMinutes(.nan), 0)
        XCTAssertEqual(ReadingTimeEstimator.displayMinutes(5), 1)
        XCTAssertEqual(ReadingTimeEstimator.displayMinutes(12 * 60), 12)
        XCTAssertEqual(ReadingTimeEstimator.displayMinutes(12 * 60 + 1), 13)
        XCTAssertEqual(ReadingTimeEstimator.displayMinutes(3 * 3600 + 18 * 60), 200)
        XCTAssertEqual(ReadingTimeEstimator.displayMinutes(3 * 3600 + 22 * 60), 200)
    }

    func testTimeStoreKeepsLatestPerBook() {
        let name = "ReadingTimeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReadingTimeStore(defaults: defaults)
        XCTAssertNil(store.latest())
        let a = ReadingTimeRemaining(documentHash: "a", bookTitle: "A", chapterSeconds: 60, bookSeconds: 600,
                                     fractionRead: 0.5, updatedAt: Date(timeIntervalSince1970: 10))
        let b = ReadingTimeRemaining(documentHash: "b", bookTitle: "B", chapterSeconds: -1, bookSeconds: 60,
                                     fractionRead: 2, updatedAt: Date(timeIntervalSince1970: 20))
        store.save(a)
        store.save(b)
        XCTAssertEqual(store.latest()?.documentHash, "b")
        XCTAssertEqual(store.load(documentHash: "b")?.chapterSeconds, 0)
        XCTAssertEqual(store.load(documentHash: "b")?.fractionRead, 1)
        store.remove(documentHash: "b")
        XCTAssertEqual(store.latest(), a)
        store.removeAll()
        XCTAssertTrue(store.all().isEmpty)
    }
}
