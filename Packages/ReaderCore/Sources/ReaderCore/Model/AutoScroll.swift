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
/// Motion model (#67): `Motion` is the distance scrolled as a function of time, linear
/// between speed changes (each change starts a new piece where the last one ended, so the text never jumps).
/// While it runs, the reader shows a `Window` of the laid-out blocks in a plain stack moved by an offset at
/// display rate (about 30 `scrollTo` re-anchors a second stepped visibly on the watch).
///
/// Position model: a `Cursor` is the block at the reading line (the viewport's top edge) and how many points of
/// it are above that line. When auto-scroll pauses or stops, `scrollTarget` turns it into a
/// `ScrollViewProxy.scrollTo(_:anchor:)` call that puts that point at the reading line of the scroll view
/// again (the same anchor math as the in-block restore, `InBlockPosition.anchorY`).
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
    /// While the text moves, the reading position is saved at most this often (and at once on pause and stop).
    public static let commitInterval: TimeInterval = 3
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

    /// Scrolling speed in text lines per second.
    public static func linesPerSecond(level: Int) -> Double {
        linesPerMinute[clampedLevel(level) - levels.lowerBound] / 60
    }

    /// Number of levels (the "7" of "speed 3 of 7").
    public static var levelCount: Int { levels.count }

    // MARK: Position

    // MARK: Motion

    /// Distance scrolled (in text lines) as a function of time: piecewise linear, one piece per speed. A speed
    /// change (or a pause, speed 0) starts a new piece at the distance reached, so the motion is continuous.
    public struct Motion: Equatable, Sendable {
        public private(set) var anchorDate: Date
        public private(set) var anchorLines: Double
        /// Lines per second (0 while paused or stopped).
        public private(set) var linesPerSecond: Double

        /// Not moving, nothing scrolled.
        public init() {
            anchorDate = .distantPast
            anchorLines = 0
            linesPerSecond = 0
        }

        /// Starts from 0 at `date`.
        public init(linesPerSecond: Double, at date: Date) {
            anchorDate = date
            anchorLines = 0
            self.linesPerSecond = Self.valid(linesPerSecond)
        }

        /// Lines scrolled at `date` (never less than at the last speed change).
        public func lines(at date: Date) -> Double {
            let elapsed = date.timeIntervalSince(anchorDate)
            guard elapsed.isFinite, elapsed > 0 else { return anchorLines }
            return anchorLines + linesPerSecond * elapsed
        }

        /// From `date` on the text moves at `linesPerSecond` (0 pauses it), continuing from where it is.
        public mutating func setSpeed(_ linesPerSecond: Double, at date: Date) {
            anchorLines = lines(at: date)
            anchorDate = max(date, anchorDate)
            self.linesPerSecond = Self.valid(linesPerSecond)
        }

        private static func valid(_ speed: Double) -> Double {
            speed.isFinite && speed > 0 ? speed : 0
        }
    }

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

    // MARK: Window

    /// The blocks the reader stacks and moves while auto-scroll runs: `first...last`, with the top of `first`
    /// at `originY - shift` in the viewport (the scroll view's coordinate space), where `shift` is the
    /// distance scrolled since the window was made. Blocks that scrolled off the top are dropped and new
    /// ones added below as their heights become known; dropping one adds its height to `originY`, so the
    /// text on screen does not move. It covers about one screen above and below the visible part, so it stays
    /// small whatever the length of the chapter.
    public struct Window: Equatable, Sendable {
        public private(set) var first: Int
        public private(set) var last: Int
        public private(set) var originY: Double
        /// `Motion` lines at the moment the window was made: `shift` is (lines now - this) * line height.
        public let baseLines: Double

        /// At most this many blocks at once (very short blocks: empty lines, headings).
        public static let maxBlocks = 60

        /// From the blocks laid out in the scroll view: the first one reaching onto the screen, down to the
        /// last one starting on it. Nil while none is.
        public init?(frames: [Int: Span], viewportHeight: Double, blockCount: Int, baseLines: Double) {
            let onScreen = frames.filter { $0.key >= 0 && $0.key < blockCount && $0.value.maxY > 0
                && $0.value.minY < max(viewportHeight, 1) }
            guard let first = onScreen.keys.min(), let last = onScreen.keys.max(),
                  let top = frames[first]?.minY, top.isFinite else { return nil }
            self.first = first
            self.last = last
            self.originY = top
            self.baseLines = baseLines
        }

        /// Top of each block of the window (at `shift`) while their heights are known, first to last.
        public func spans(heights: [Int: Double], spacing: Double, shift: Double) -> [Int: Span] {
            var result: [Int: Span] = [:]
            var y = originY - shift
            for index in first...last {
                guard let height = heights[index], height.isFinite, height >= 0 else { break }
                result[index] = Span(minY: y, maxY: y + height)
                y += height + spacing
            }
            return result
        }

        /// The shift at which the bottom of the book reaches the bottom of the viewport, once the last block
        /// is in the window and every height is known (nil before).
        public func endShift(heights: [Int: Double], spacing: Double, viewportHeight: Double,
                             blockCount: Int) -> Double? {
            guard blockCount > 0, last == blockCount - 1 else { return nil }
            let spans = spans(heights: heights, spacing: spacing, shift: 0)
            guard let bottom = spans[last]?.maxY else { return nil }
            return max(bottom - viewportHeight, 0)
        }

        /// Drops blocks that scrolled off the top (more than `margin` above it) and adds blocks below until
        /// the window reaches `margin` past the bottom. Returns whether it changed.
        @discardableResult
        public mutating func update(heights: [Int: Double], spacing: Double, shift: Double,
                                    viewportHeight: Double, blockCount: Int, margin: Double) -> Bool {
            var changed = false
            while first < last, let height = heights[first], height.isFinite,
                  originY - shift + height < -margin {
                originY += height + spacing
                first += 1
                changed = true
            }
            while last < blockCount - 1, last - first + 1 < Self.maxBlocks {
                let spans = spans(heights: heights, spacing: spacing, shift: shift)
                // Wait for the newest block to be measured before adding another.
                guard let bottom = spans[last]?.maxY, bottom < viewportHeight + margin else { break }
                last += 1
                changed = true
            }
            return changed
        }
    }
}
