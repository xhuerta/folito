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

    /// Each crown detent must be a change the reader sees (#67: level 3 to 4 was 28 to 35 lines a minute and
    /// looked like nothing happened): roughly geometric, about 10 to 90 lines a minute over the seven levels.
    func testLevelsAreClearlyDifferent() {
        let lines = AutoScroll.linesPerMinute
        XCTAssertEqual(lines, [12, 17, 24, 33, 46, 64, 90])
        for i in 1..<lines.count {
            let ratio = lines[i] / lines[i - 1]
            XCTAssertGreaterThanOrEqual(ratio, AutoScroll.minLevelRatio, "level \(i) to \(i + 1)")
            XCTAssertLessThan(ratio, 1.6, "level \(i) to \(i + 1) is not a jump")
        }
        XCTAssertGreaterThanOrEqual(lines.last! / lines.first!, 7, "a wide range from slow to skimming")
        XCTAssertGreaterThanOrEqual(lines.first!, 10)
        XCTAssertLessThanOrEqual(lines.last!, 90)
        // The default is a relaxed pace in the middle-low part of the range, as before.
        XCTAssertEqual(AutoScroll.defaultLevel, 3)
        XCTAssertEqual(lines[AutoScroll.defaultLevel - 1], 24)
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
        XCTAssertEqual(AutoScroll.pointsPerSecond(level: 3, lineHeight: line), 24 * line / 60, accuracy: 1e-9)
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

    func testLinesPerSecond() {
        XCTAssertEqual(AutoScroll.linesPerSecond(level: 3), 24.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(AutoScroll.linesPerSecond(level: 99), 90.0 / 60, accuracy: 1e-12)
    }

    // MARK: motion

    func testMotionIsLinearAndContinuousAcrossSpeedChanges() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var motion = AutoScroll.Motion(linesPerSecond: 0.4, at: t0)
        XCTAssertEqual(motion.lines(at: t0), 0)
        XCTAssertEqual(motion.lines(at: t0 + 10), 4, accuracy: 1e-9)
        // Before the start (a clock read a moment early): no negative distance.
        XCTAssertEqual(motion.lines(at: t0 - 1), 0)

        // Faster at t0 + 10: no jump at the change, the new slope after it.
        motion.setSpeed(1.5, at: t0 + 10)
        XCTAssertEqual(motion.lines(at: t0 + 10), 4, accuracy: 1e-9)
        XCTAssertEqual(motion.lines(at: t0 + 12), 7, accuracy: 1e-9)

        // Paused: stays where it is.
        motion.setSpeed(0, at: t0 + 12)
        XCTAssertEqual(motion.lines(at: t0 + 100), 7, accuracy: 1e-9)
        // Resumed: continues from there.
        motion.setSpeed(0.4, at: t0 + 100)
        XCTAssertEqual(motion.lines(at: t0 + 105), 9, accuracy: 1e-9)
        // Bad speeds stop it rather than move it backwards or to infinity.
        motion.setSpeed(-3, at: t0 + 105)
        XCTAssertEqual(motion.lines(at: t0 + 200), 9, accuracy: 1e-9)
        motion.setSpeed(.nan, at: t0 + 200)
        XCTAssertEqual(motion.lines(at: t0 + 300), 9, accuracy: 1e-9)
        XCTAssertEqual(AutoScroll.Motion().lines(at: t0), 0)
    }

    // MARK: window

    func testWindowFromLaidOutBlocksAndItsSpans() throws {
        // Viewport 200 pt; block 0 is scrolled away above, 1 reaches onto the screen, 4 starts below it.
        let laidOut: [Int: AutoScroll.Span] = [
            0: .init(minY: -150, maxY: -60), 1: .init(minY: -50, maxY: 50), 2: .init(minY: 60, maxY: 160),
            3: .init(minY: 170, maxY: 270), 4: .init(minY: 280, maxY: 380),
        ]
        let window = try XCTUnwrap(AutoScroll.Window(frames: laidOut, viewportHeight: 200, blockCount: 10, baseLines: 2))
        XCTAssertEqual(window.first, 1)
        XCTAssertEqual(window.last, 3)
        XCTAssertEqual(window.originY, -50)
        XCTAssertEqual(window.baseLines, 2)
        let heights: [Int: Double] = [1: 100, 2: 100, 3: 100]
        // Same places as in the scroll view, then moved up by the shift.
        XCTAssertEqual(window.spans(heights: heights, spacing: 10, shift: 0)[2], .init(minY: 60, maxY: 160))
        XCTAssertEqual(window.spans(heights: heights, spacing: 10, shift: 25)[3], .init(minY: 145, maxY: 245))
        // A block whose height is not known yet ends the spans.
        XCTAssertNil(window.spans(heights: [1: 100], spacing: 10, shift: 0)[2])
        XCTAssertNil(AutoScroll.Window(frames: [:], viewportHeight: 200, blockCount: 10, baseLines: 0))
    }

    func testWindowDropsAndAddsBlocksWithoutMovingTheText() throws {
        let laidOut: [Int: AutoScroll.Span] = [0: .init(minY: 0, maxY: 100), 1: .init(minY: 110, maxY: 210)]
        var window = try XCTUnwrap(AutoScroll.Window(frames: laidOut, viewportHeight: 200, blockCount: 6, baseLines: 0))
        let heights: [Int: Double] = Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, 100.0) })
        // Fills below the screen (margin 50: down to 250).
        XCTAssertTrue(window.update(heights: heights, spacing: 10, shift: 0, viewportHeight: 200, blockCount: 6, margin: 50))
        XCTAssertEqual(window.first, 0)
        XCTAssertEqual(window.last, 2)
        let before = window.spans(heights: heights, spacing: 10, shift: 180)[2]

        // Scrolled 180 pt: block 0 (bottom at -80) is more than 50 pt above the screen and goes; block 1 stays.
        XCTAssertTrue(window.update(heights: heights, spacing: 10, shift: 180, viewportHeight: 200, blockCount: 6, margin: 50))
        XCTAssertEqual(window.first, 1)
        XCTAssertEqual(window.originY, 110)
        // Block 2 is exactly where it was: dropping block 0 did not move the text.
        XCTAssertEqual(window.spans(heights: heights, spacing: 10, shift: 180)[2], before)
        XCTAssertEqual(window.last, 3, "block 3 ends at 250: the margin is reached")

        // Nothing to do: no change.
        XCTAssertFalse(window.update(heights: heights, spacing: 10, shift: 180, viewportHeight: 200, blockCount: 6, margin: 50))
        // A block not measured yet is not followed by another.
        var waiting = try XCTUnwrap(AutoScroll.Window(frames: laidOut, viewportHeight: 200, blockCount: 6, baseLines: 0))
        waiting.update(heights: [0: 100, 1: 100], spacing: 10, shift: 0, viewportHeight: 200, blockCount: 6, margin: 50)
        XCTAssertEqual(waiting.last, 2)
        waiting.update(heights: [0: 100, 1: 100], spacing: 10, shift: 0, viewportHeight: 200, blockCount: 6, margin: 50)
        XCTAssertEqual(waiting.last, 2, "waits for block 2's height")
    }

    func testWindowEndShift() throws {
        let laidOut: [Int: AutoScroll.Span] = [0: .init(minY: 0, maxY: 100), 1: .init(minY: 110, maxY: 210)]
        var window = try XCTUnwrap(AutoScroll.Window(frames: laidOut, viewportHeight: 200, blockCount: 3, baseLines: 0))
        let heights: [Int: Double] = [0: 100, 1: 100, 2: 100]
        XCTAssertNil(window.endShift(heights: heights, spacing: 10, viewportHeight: 200, blockCount: 3), "last block not in it")
        window.update(heights: heights, spacing: 10, shift: 0, viewportHeight: 200, blockCount: 3, margin: 50)
        XCTAssertEqual(window.last, 2)
        // The book ends at 320: the end is reached after 120 pt.
        XCTAssertEqual(try XCTUnwrap(window.endShift(heights: heights, spacing: 10, viewportHeight: 200, blockCount: 3)),
                       120, accuracy: 1e-9)
        XCTAssertNil(window.endShift(heights: [0: 100, 1: 100], spacing: 10, viewportHeight: 200, blockCount: 3))
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
