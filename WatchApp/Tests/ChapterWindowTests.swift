import XCTest
@testable import FolitoWatch

/// The reader's chapter window (`ChapterWindow`, build 49 feedback): which blocks the scroll view holds.
final class ChapterWindowTests: XCTestCase {
    /// Chapters of 10, 3, 0 (empty: shares its start with the next), 20 and 5 blocks.
    private let starts = [0, 10, 13, 13, 33]
    private let count = 38

    func testChapterRangeFindsTheSpineChapter() {
        XCTAssertEqual(ChapterWindow.chapterRange(containing: 0, chapterStarts: starts, count: count), 0..<10)
        XCTAssertEqual(ChapterWindow.chapterRange(containing: 9, chapterStarts: starts, count: count), 0..<10)
        XCTAssertEqual(ChapterWindow.chapterRange(containing: 10, chapterStarts: starts, count: count), 10..<13)
        XCTAssertEqual(ChapterWindow.chapterRange(containing: 13, chapterStarts: starts, count: count), 13..<33,
                       "an empty chapter shares its start with the next")
        XCTAssertEqual(ChapterWindow.chapterRange(containing: 37, chapterStarts: starts, count: count), 33..<38)
        XCTAssertEqual(ChapterWindow.chapterRange(containing: 99, chapterStarts: starts, count: count), 33..<38, "clamped")
        XCTAssertEqual(ChapterWindow.chapterRange(containing: 0, chapterStarts: [], count: 0), 0..<0)
    }

    /// A jump loads the target's chapter, plus following chapters until `minimumBelow` blocks follow the target.
    func testWindowForAJumpStartsAtTheChapterAndLeavesRoomBelow() {
        XCTAssertEqual(ChapterWindow.window(for: 13, chapterStarts: starts, count: count), 13..<33,
                       "a chapter start: its chapter only, nothing above the target")
        XCTAssertEqual(ChapterWindow.window(for: 10, chapterStarts: starts, count: count), 10..<33,
                       "a short chapter takes the next one too, so its start can reach the top")
        XCTAssertEqual(ChapterWindow.window(for: 30, chapterStarts: starts, count: count), 13..<38,
                       "near a chapter's end: the next chapter as well")
        XCTAssertEqual(ChapterWindow.window(for: 36, chapterStarts: starts, count: count), 33..<38, "the book's end")
        for target in 0..<count {
            let window = ChapterWindow.window(for: target, chapterStarts: starts, count: count)
            XCTAssertTrue(window.contains(target), "\(target) in \(window)")
            XCTAssertTrue(window.upperBound - target >= ChapterWindow.minimumBelow || window.upperBound == count)
            XCTAssertTrue(starts.contains(window.lowerBound), "a window starts at a chapter start")
        }
    }

    /// Reading forward appends whole chapters below, never changing the window's start.
    func testAppendingKeepsTheStartAndAddsTheNextChapter() {
        XCTAssertEqual(ChapterWindow.appendingNextChapter(to: 0..<10, chapterStarts: starts, count: count), 0..<13)
        XCTAssertEqual(ChapterWindow.appendingNextChapter(to: 0..<13, chapterStarts: starts, count: count), 0..<33)
        XCTAssertEqual(ChapterWindow.appendingNextChapter(to: 13..<38, chapterStarts: starts, count: count), 13..<38,
                       "nothing after the book's end")
    }

    func testAppendIsNeededOnlyNearTheLoadedEnd() {
        XCTAssertFalse(ChapterWindow.needsAppend(lastLaidOut: nil, window: 13..<33, count: count))
        XCTAssertFalse(ChapterWindow.needsAppend(lastLaidOut: 20, window: 13..<33, count: count))
        XCTAssertTrue(ChapterWindow.needsAppend(lastLaidOut: 33 - ChapterWindow.appendMargin, window: 13..<33, count: count))
        XCTAssertFalse(ChapterWindow.needsAppend(lastLaidOut: 37, window: 33..<38, count: count), "the book's end")
    }

    func testPreviousChapterStart() {
        XCTAssertNil(ChapterWindow.previousChapterStart(before: 0..<13, chapterStarts: starts, count: count))
        XCTAssertEqual(ChapterWindow.previousChapterStart(before: 13..<33, chapterStarts: starts, count: count), 10)
        XCTAssertEqual(ChapterWindow.previousChapterStart(before: 33..<38, chapterStarts: starts, count: count), 13)
    }

    /// The auto-scroll hand-back extends the window below without moving its start; above it, nothing.
    func testExtendingBelowKeepsTheStart() {
        XCTAssertEqual(ChapterWindow.extended(0..<10, toHold: 9, chapterStarts: starts, count: count), 0..<33)
        XCTAssertEqual(ChapterWindow.extended(13..<38, toHold: 20, chapterStarts: starts, count: count), 13..<38)
        XCTAssertNil(ChapterWindow.extended(13..<33, toHold: 5, chapterStarts: starts, count: count))
    }

    /// Rows keep their frames in the stack; scrolling moves only the stack. The frames handed on are the window's rows
    /// near the viewport, in the scroll view's space and on screen.
    func testFrameStoreMapsRowsNearTheViewport() {
        let store = BlockFrameStore()
        XCTAssertTrue(store.frames(window: 0..<10, viewportHeight: 130).isEmpty, "nothing before the stack is placed")
        for index in 0..<10 {
            store.rows[index] = CGRect(x: 0, y: CGFloat(index) * 100, width: 150, height: 90)
        }
        store.rows[42] = CGRect(x: 0, y: 0, width: 150, height: 90) // a row of another window
        store.stackInScroll = CGRect(x: 6, y: -250, width: 150, height: 1000)
        store.stackScreenMinY = -202.5
        let frames = store.frames(window: 0..<10, viewportHeight: 130)
        XCTAssertEqual(Set(frames.keys), Set(1...5), "within one viewport above and below")
        XCTAssertEqual(frames[2], BlockFrame(minY: -50, maxY: 40, width: 150, minX: 6, screenMinY: -2.5))
        XCTAssertNil(frames[42], "rows outside the window are left out")
    }
}
