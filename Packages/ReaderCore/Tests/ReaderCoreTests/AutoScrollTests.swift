import XCTest
@testable import ReaderCore

/// Auto-scroll on the watch (#67): speed levels, crown mapping, steps and the cursor / scrollTo math.
final class AutoScrollTests: XCTestCase {
    // MARK: levels

    func testLevelsAndDefault() {
        XCTAssertEqual(AutoScroll.levels, 1...7)
        XCTAssertEqual(AutoScroll.levelCount, 7)
        XCTAssertEqual(AutoScroll.linesPerMinute.count, AutoScroll.levelCount)
        XCTAssertTrue(AutoScroll.levels.contains(AutoScroll.defaultLevel))
        XCTAssertEqual(AutoScroll.linesPerMinute, AutoScroll.linesPerMinute.sorted(), "slowest first")
    }

    func testClampingAndStoredLevel() {
        XCTAssertEqual(AutoScroll.clampedLevel(0), 1)
        XCTAssertEqual(AutoScroll.clampedLevel(-4), 1)
        XCTAssertEqual(AutoScroll.clampedLevel(5), 5)
        XCTAssertEqual(AutoScroll.clampedLevel(99), 7)
        // Nothing stored reads as 0 from UserDefaults: the default level.
        XCTAssertEqual(AutoScroll.storedLevel(0), AutoScroll.defaultLevel)
        XCTAssertEqual(AutoScroll.storedLevel(12), AutoScroll.defaultLevel)
        XCTAssertEqual(AutoScroll.storedLevel(6), 6)
    }

    func testReduceMotionStartsGently() {
        XCTAssertEqual(AutoScroll.startLevel(saved: 6, reduceMotion: true), AutoScroll.reduceMotionMaxLevel)
        XCTAssertEqual(AutoScroll.startLevel(saved: 2, reduceMotion: true), 2)
        XCTAssertEqual(AutoScroll.startLevel(saved: 6, reduceMotion: false), 6)
        XCTAssertEqual(AutoScroll.startLevel(saved: 0, reduceMotion: false), AutoScroll.defaultLevel)
    }

    func testCrownValueToLevel() {
        XCTAssertEqual(AutoScroll.level(forCrown: 3), 3)
        XCTAssertEqual(AutoScroll.level(forCrown: 3.4), 3)
        XCTAssertEqual(AutoScroll.level(forCrown: 3.6), 4)
        XCTAssertEqual(AutoScroll.level(forCrown: -2), 1)
        XCTAssertEqual(AutoScroll.level(forCrown: 40), 7)
        XCTAssertEqual(AutoScroll.level(forCrown: .nan), AutoScroll.defaultLevel)
        XCTAssertEqual(AutoScroll.level(forCrown: .infinity), AutoScroll.defaultLevel)
    }

    // MARK: speed

    func testLineHeight() {
        XCTAssertEqual(AutoScroll.lineHeight(pointSize: 16, lineSpacing: 0), 19.2, accuracy: 1e-9)
        XCTAssertEqual(AutoScroll.lineHeight(pointSize: 20, lineSpacing: 4), 28, accuracy: 1e-9)
        XCTAssertEqual(AutoScroll.lineHeight(pointSize: 16, lineSpacing: -3), 19.2, accuracy: 1e-9)
        XCTAssertEqual(AutoScroll.lineHeight(pointSize: 0, lineSpacing: 0), 19.2, accuracy: 1e-9)
    }

    func testPointsPerSecondFollowsLevelAndTextSize() {
        let line = 19.2
        XCTAssertEqual(AutoScroll.pointsPerSecond(level: 3, lineHeight: line), 28 * line / 60, accuracy: 1e-9)
        for level in 1..<7 {
            XCTAssertLessThan(AutoScroll.pointsPerSecond(level: level, lineHeight: line),
                              AutoScroll.pointsPerSecond(level: level + 1, lineHeight: line))
        }
        // Bigger text: same lines per minute, more points.
        XCTAssertEqual(AutoScroll.pointsPerSecond(level: 3, lineHeight: 2 * line),
                       2 * AutoScroll.pointsPerSecond(level: 3, lineHeight: line), accuracy: 1e-9)
        // Out-of-range levels are clamped.
        XCTAssertEqual(AutoScroll.pointsPerSecond(level: 50, lineHeight: line),
                       AutoScroll.pointsPerSecond(level: 7, lineHeight: line))
    }

    func testStepsAreSmallAndBounded() {
        let line = 19.2
        let tick = AutoScroll.step(level: 7, lineHeight: line, elapsed: AutoScroll.tickInterval)
        XCTAssertGreaterThan(tick, 0)
        XCTAssertLessThan(tick, 2, "a tick at the fastest level stays under 2 pt at the default size")
        XCTAssertEqual(AutoScroll.step(level: 3, lineHeight: line, elapsed: 0), 0)
        XCTAssertEqual(AutoScroll.step(level: 3, lineHeight: line, elapsed: -1), 0)
        XCTAssertEqual(AutoScroll.step(level: 3, lineHeight: line, elapsed: .nan), 0)
        // A long stall moves the text by at most `maxElapsed` seconds' worth.
        XCTAssertEqual(AutoScroll.step(level: 3, lineHeight: line, elapsed: 5),
                       AutoScroll.pointsPerSecond(level: 3, lineHeight: line) * AutoScroll.maxElapsed, accuracy: 1e-9)
    }

    // MARK: cursor

    /// Three blocks 100 pt tall with 10 pt between them, the first starting 20 pt above the viewport top (30).
    private let frames: [Int: AutoScroll.Span] = [
        0: .init(minY: 10, maxY: 110),
        1: .init(minY: 120, maxY: 220),
        2: .init(minY: 230, maxY: 330),
    ]

    func testCursorFromFrames() {
        XCTAssertEqual(AutoScroll.cursor(frames: frames, viewportTop: 30), .init(index: 0, offset: 20))
        // Block 0 ends within the threshold of the line: block 1 is the one being read.
        XCTAssertEqual(AutoScroll.cursor(frames: frames, viewportTop: 108), .init(index: 1, offset: 0))
        XCTAssertNil(AutoScroll.cursor(frames: [:], viewportTop: 30))
    }

    func testAdvanceCrossesBlocks() {
        let start = AutoScroll.Cursor(index: 0, offset: 20)
        XCTAssertEqual(AutoScroll.advance(start, by: 50, blockCount: 3, frames: frames), .init(index: 0, offset: 70))
        // 20 + 100 = 120: 110 to the next block's top, 10 into it.
        XCTAssertEqual(AutoScroll.advance(start, by: 100, blockCount: 3, frames: frames), .init(index: 1, offset: 10))
        XCTAssertEqual(AutoScroll.advance(start, by: 230, blockCount: 3, frames: frames), .init(index: 2, offset: 30))
        // Never past the last block.
        XCTAssertEqual(AutoScroll.advance(start, by: 1000, blockCount: 3, frames: frames).index, 2)
        // A negative or bad delta does not move it back.
        XCTAssertEqual(AutoScroll.advance(start, by: -5, blockCount: 3, frames: frames), start)
        XCTAssertEqual(AutoScroll.advance(start, by: .nan, blockCount: 3, frames: frames), start)
        // Next block not laid out: stays in its block for now.
        XCTAssertEqual(AutoScroll.advance(start, by: 150, blockCount: 3, frames: [0: frames[0]!]),
                       .init(index: 0, offset: 170))
    }

    func testEndOfBook() {
        // Last block ends below the viewport bottom: not yet.
        XCTAssertFalse(AutoScroll.isAtEnd(cursor: .init(index: 1, offset: 0), blockCount: 3, frames: frames,
                                          viewportTop: 30, viewportHeight: 200))
        // Last block's bottom on screen.
        XCTAssertTrue(AutoScroll.isAtEnd(cursor: .init(index: 1, offset: 0), blockCount: 3, frames: frames,
                                         viewportTop: 30, viewportHeight: 330))
        // Cursor far enough into the last block that its bottom reaches the viewport bottom.
        // (Viewport 100, reading line at 30: 70 pt of text below the line, the last block is 100 pt tall.)
        XCTAssertTrue(AutoScroll.isAtEnd(cursor: .init(index: 2, offset: 40), blockCount: 3, frames: frames,
                                         viewportTop: 30, viewportHeight: 100))
        XCTAssertFalse(AutoScroll.isAtEnd(cursor: .init(index: 2, offset: 10), blockCount: 3, frames: frames,
                                          viewportTop: 30, viewportHeight: 100))
        XCTAssertTrue(AutoScroll.isAtEnd(cursor: nil, blockCount: 0, frames: [:], viewportTop: 0, viewportHeight: 100))
    }

    // MARK: scrollTo

    /// Where `scrollTo(index, anchor: y)` puts the top of the cursor's block (the model the anchor math uses).
    private func landedTop(_ target: AutoScroll.Target, cursor: AutoScroll.Cursor, viewportHeight: Double) -> Double {
        let ref = frames[target.index]!
        let refTop = target.anchorY * (viewportHeight - ref.height)
        return refTop - (ref.minY - frames[cursor.index]!.minY)
    }

    func testScrollTargetPutsTheCursorAtTheReadingLine() throws {
        let cursor = AutoScroll.Cursor(index: 1, offset: 40)
        let target = try XCTUnwrap(AutoScroll.scrollTarget(cursor, frames: frames, viewportTop: 30, viewportHeight: 200))
        XCTAssertEqual(target.index, 1)
        // Block top at 30 - 40 = -10.
        XCTAssertEqual(landedTop(target, cursor: cursor, viewportHeight: 200), -10, accuracy: 1e-9)
        // Same as the restore's anchor for that fraction of the block.
        let restore = try XCTUnwrap(InBlockPosition.anchorY(fraction: 0.4, blockHeight: 100, viewportHeight: 200,
                                                            viewportTop: 30))
        XCTAssertEqual(target.anchorY, restore, accuracy: 1e-9)
    }

    func testScrollTargetAvoidsABlockAsTallAsTheViewport() throws {
        // Viewport 100 pt: every block is as tall as it, the anchor through them is undefined. Only the
        // previous / next block with a different height can be the reference.
        var mixed = frames
        mixed[2] = .init(minY: 230, maxY: 280)
        let cursor = AutoScroll.Cursor(index: 1, offset: 40)
        let target = try XCTUnwrap(AutoScroll.scrollTarget(cursor, frames: mixed, viewportTop: 30, viewportHeight: 100))
        XCTAssertEqual(target.index, 2)
        let ref = mixed[2]!
        let refTop = target.anchorY * (100 - ref.height)
        XCTAssertEqual(refTop - (ref.minY - mixed[1]!.minY), -10, accuracy: 1e-9)
        XCTAssertNil(AutoScroll.scrollTarget(cursor, frames: frames, viewportTop: 30, viewportHeight: 100))
        XCTAssertNil(AutoScroll.scrollTarget(.init(index: 7, offset: 0), frames: frames, viewportTop: 30, viewportHeight: 200))
        XCTAssertNil(AutoScroll.scrollTarget(cursor, frames: frames, viewportTop: 30, viewportHeight: 0))
    }
}
