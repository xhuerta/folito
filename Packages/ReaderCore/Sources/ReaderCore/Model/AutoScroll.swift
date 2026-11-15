import Foundation

/// Speed and step math for the watch reader's auto-scroll (#67). Pure, so it is unit-tested on Linux.
///
/// Speed model: a few levels (`levels`, 1...7), each a number of text lines per minute (`linesPerMinute`).
/// Lines, not points, so a level reads at the same pace whatever the text size: the view turns lines into
/// points with the body text's line height (`lineHeight(pointSize:lineSpacing:)`). The levels are roughly
/// geometric (each about 1.4 times the one before, 12 to 90 lines per minute), so one crown detent is a change
/// the reader sees at once: the first table (16 to 64, about 1.25 times per level) made level 3 to 4 a change
/// nobody noticed on the watch (#67). With about five to six words per line on a 41-45 mm watch at the default
/// 16 pt, level 1 is roughly 60-70 words per minute, the default level 3 roughly 120-145 and level 7 a fast
/// skim. The level is one per user (not per book) and is changed with the Digital Crown while the text scrolls;
/// the stored setting is the level (1...7), so a saved speed keeps its meaning as "level n".
///
/// Position model: a `Cursor` is the block at the reading line (the viewport's top edge) and how many points of
/// it are above that line. Every tick moves it forward by `step(level:lineHeight:elapsed:)` points, across
/// blocks with the distances measured between laid-out blocks, and `scrollTarget` turns it into a
/// `ScrollViewProxy.scrollTo(_:anchor:)` call that puts that point at the reading line (the same anchor math as
/// the in-block restore, `InBlockPosition.anchorY`).
public enum AutoScroll {
    /// The speed levels, slowest first.
    public static let levels: ClosedRange<Int> = 1...7
    /// The level used before the user picked one: a relaxed reading pace.
    public static let defaultLevel = 3
    /// With Reduce Motion on, auto-scroll starts no faster than this (the user can still turn it up).
    public static let reduceMotionMaxLevel = 3
    /// Text lines per minute for each level (index 0 is level 1): about 1.4 times per level.
    public static let linesPerMinute: [Double] = [12, 17, 24, 33, 46, 64, 90]
    /// Every level is at least this many times faster than the one below it, so a single crown detent is a
    /// visible change.
    public static let minLevelRatio = 1.3
    /// How often the view moves the text: about 30 times a second, smooth on the watch at these speeds
    /// (under 2 pt per tick at the fastest level, even at the largest text size).
    public static let tickInterval: TimeInterval = 1.0 / 30.0
    /// A longer gap between two ticks (the app was busy, a frame was dropped) moves the text by at most this
    /// much time's worth, so the text never jumps.
    public static let maxElapsed: TimeInterval = 0.25
    /// A block whose height is within this many points of the viewport's height cannot be used as the
    /// `scrollTo` anchor reference (the anchor math divides by the difference).
    public static let minAnchorSpan = 8.0

    /// `level` within `levels`.
    public static func clampedLevel(_ level: Int) -> Int {
        min(max(level, levels.lowerBound), levels.upperBound)
    }

    /// The level stored in settings, or the default when nothing (0) or a bad value is stored.
    public static func storedLevel(_ raw: Int) -> Int {
        levels.contains(raw) ? raw : defaultLevel
    }

    /// The level auto-scroll starts at: the saved one, capped at `reduceMotionMaxLevel` with Reduce Motion on.
    public static func startLevel(saved: Int, reduceMotion: Bool) -> Int {
        let level = storedLevel(saved)
        return reduceMotion ? min(level, reduceMotionMaxLevel) : level
    }

    /// The level for a Digital Crown value (the crown runs over `levels` with one detent per level).
    public static func level(forCrown value: Double) -> Int {
        guard value.isFinite else { return defaultLevel }
        return clampedLevel(Int(value.rounded()))
    }

    /// Height of one line of body text: the font's point size with the usual 1.2 leading, plus the extra
    /// line spacing of the typography settings.
    public static func lineHeight(pointSize: Double, lineSpacing: Double) -> Double {
        let size = pointSize.isFinite && pointSize > 0 ? pointSize : 16
        let extra = lineSpacing.isFinite ? max(lineSpacing, 0) : 0
        return size * 1.2 + extra
    }

    /// Scrolling speed in points per second.
    public static func pointsPerSecond(level: Int, lineHeight: Double) -> Double {
        let lines = linesPerMinute[clampedLevel(level) - levels.lowerBound]
        let height = lineHeight.isFinite && lineHeight > 0 ? lineHeight : 19.2
        return lines * height / 60
    }

    /// Points to move for `elapsed` seconds since the previous tick (0 for a negative or bad interval, at most
    /// `maxElapsed` seconds' worth).
    public static func step(level: Int, lineHeight: Double, elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return pointsPerSecond(level: level, lineHeight: lineHeight) * min(elapsed, maxElapsed)
    }

    /// Number of levels (the "7" of "speed 3 of 7").
    public static var levelCount: Int { levels.count }

    // MARK: Position

    /// Vertical extent of a laid-out block in the scroll view's coordinate space.
    public struct Span: Equatable, Sendable {
        public var minY: Double
        public var maxY: Double
        public init(minY: Double, maxY: Double) {
            self.minY = minY
            self.maxY = maxY
        }
        public var height: Double { maxY - minY }
    }

    /// The block at the reading line and how many points of it are above that line.
    public struct Cursor: Equatable, Sendable {
        public var index: Int
        public var offset: Double
        public init(index: Int, offset: Double) {
            self.index = index
            self.offset = offset
        }
    }

    /// Where the reading line is now, from the laid-out blocks: the first block reaching below the line
    /// (by more than `threshold` points, as the reader's position tracking does) and the part of it above it.
    public static func cursor(frames: [Int: Span], viewportTop: Double, threshold: Double = 4) -> Cursor? {
        guard let index = frames.filter({ $0.value.maxY > viewportTop + threshold }).keys.min(),
              let frame = frames[index] else { return nil }
        return Cursor(index: index, offset: max(viewportTop - frame.minY, 0))
    }

    /// Distance from the top of block `index` to the top of the next one (its height plus the spacing), when
    /// both are laid out.
    static func distanceToNext(_ index: Int, frames: [Int: Span]) -> Double? {
        guard let this = frames[index], let next = frames[index + 1] else { return nil }
        let distance = next.minY - this.minY
        return distance.isFinite && distance > 0 ? distance : nil
    }

    /// `cursor` moved forward by `delta` points, into the following blocks while their distances are known. It
    /// never moves past the last block (`blockCount`).
    public static func advance(_ cursor: Cursor, by delta: Double, blockCount: Int, frames: [Int: Span]) -> Cursor {
        var result = cursor
        if delta.isFinite, delta > 0 { result.offset += delta }
        while result.index < blockCount - 1, let distance = distanceToNext(result.index, frames: frames),
              result.offset >= distance {
            result.offset -= distance
            result.index += 1
        }
        return result
    }

    /// Whether auto-scroll has reached the end of the book: the bottom of the last block is at (or above) the
    /// bottom of the viewport, so the text cannot scroll further.
    public static func isAtEnd(cursor: Cursor?, blockCount: Int, frames: [Int: Span],
                               viewportTop: Double, viewportHeight: Double) -> Bool {
        guard blockCount > 0 else { return true }
        let last = blockCount - 1
        if let frame = frames[last], frame.maxY <= viewportHeight + 0.5 { return true }
        guard let cursor, cursor.index == last, let frame = frames[last] else { return false }
        return cursor.offset >= frame.height - (viewportHeight - viewportTop)
    }

    /// A `scrollTo` call: the block id and the vertical `UnitPoint` anchor.
    public struct Target: Equatable, Sendable {
        public var index: Int
        public var anchorY: Double
    }

    /// The `scrollTo` call that puts the cursor's point at the reading line (`viewportTop`).
    ///
    /// `scrollTo(i, anchor: y)` puts the top of block `i` (height `H`) at `y * (V - H)` in a viewport of height
    /// `V` (see `InBlockPosition.anchorY`). The cursor's block is the reference; when it is about as tall as
    /// the viewport (the anchor would be undefined) the next block is used instead, else the previous one.
    /// Nil while none of them is laid out.
    public static func scrollTarget(_ cursor: Cursor, frames: [Int: Span], viewportTop: Double,
                                    viewportHeight: Double) -> Target? {
        guard viewportHeight > 0, viewportHeight.isFinite, viewportTop.isFinite,
              let base = frames[cursor.index] else { return nil }
        // Where each candidate's top must be, relative to the reading line.
        var candidates: [(index: Int, top: Double)] = [(cursor.index, -cursor.offset)]
        if let next = frames[cursor.index + 1] {
            candidates.append((cursor.index + 1, next.minY - base.minY - cursor.offset))
        }
        if let previous = frames[cursor.index - 1] {
            candidates.append((cursor.index - 1, previous.minY - base.minY - cursor.offset))
        }
        for candidate in candidates {
            guard let frame = frames[candidate.index] else { continue }
            let span = viewportHeight - frame.height
            guard abs(span) >= minAnchorSpan else { continue }
            let y = (viewportTop + candidate.top) / span
            guard y.isFinite else { continue }
            return Target(index: candidate.index, anchorY: y)
        }
        return nil
    }
}
