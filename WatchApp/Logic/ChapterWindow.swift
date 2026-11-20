import Foundation
import CoreGraphics

/// Which blocks the reader's scroll view holds: the chapter being read, not the whole book.
///
/// A lazy stack places the blocks it has not measured on estimated heights, and moves everything when it measures
/// them; with the whole book loaded, a jump far into it never settled. With one chapter loaded (in a plain stack,
/// see `ReaderView`), a chapter's start has nothing above it, and anything above a target is laid out exactly.
///
/// - A jump (chapter, bookmark, synced position, opening) to a block outside the window loads the target's chapter,
///   plus the following chapters until at least `minimumBelow` blocks follow the target, so it can reach the top.
/// - Reading forward appends the next chapter below once the last loaded blocks are laid out (`needsAppend`).
///   Appending below never moves what is on screen; nothing is ever inserted or removed above it while reading.
/// - A layout change reloads the current chapter (the scroll view is rebuilt for it anyway): earlier chapters
///   appended while reading are trimmed only then, on a jump or when the book is reopened.
/// - A spare chapter stays loaded above the one being read: once the reader is in the window's first chapter (right
///   after landing at a chapter's start, or after reading up into it), the chapter before it is prepended
///   (`needsPrepend`), as soon as the scroll is idle; within `prependMargin` blocks of the edge (a fast fling) at
///   once, even while scrolling (`prependIsUrgent`). The reader scrolls to the same point of the block at the reading
///   line in the same update as the new rows, and the view model checks it once laid out, correcting it only if
///   nobody scrolled meanwhile. Chapters far below the reader are dropped then (`trimmedBelow`), which never moves
///   what is on screen.
///
/// Chapters are the book's spine chapters (`FlatBook.chapterStarts`, flat indices). Positions stay global.
enum ChapterWindow {
    /// Blocks a loaded window keeps below a jump's target (about a few screens), so the target can reach the top.
    static let minimumBelow = 12
    /// Append the next chapter once a block this close to the window's end is laid out: well before a fling can reach
    /// the end of the loaded blocks and bounce back from it.
    static let appendMargin = 12

    /// The spine chapter holding block `index`: from the last chapter start at or before it to the next start after
    /// it (empty chapters share their start with the next one), or the end of the book.
    static func chapterRange(containing index: Int, chapterStarts: [Int], count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let i = min(max(index, 0), count - 1)
        var lower = 0
        var upper = count
        for start in chapterStarts {
            if start <= i {
                lower = max(lower, start)
            } else if start < upper {
                upper = start
            }
        }
        return lower..<upper
    }

    /// Prepend the previous chapter at once, even while scrolling, when the block at the reading line is this close to
    /// the window's first block.
    static let prependMargin = 12

    /// The window a jump to `target` loads: its chapter, extended by the following chapters until at least
    /// `minimumBelow` blocks follow the target (or the book ends). The chapter before it is prepended once the reader
    /// has landed (`needsPrepend`), so a jump only lays out what it needs.
    static func window(for target: Int, chapterStarts: [Int], count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let chapter = chapterRange(containing: target, chapterStarts: chapterStarts, count: count)
        var upper = chapter.upperBound
        while upper < count && upper - target < minimumBelow {
            upper = chapterRange(containing: upper, chapterStarts: chapterStarts, count: count).upperBound
        }
        return chapter.lowerBound..<upper
    }

    /// `window` with the previous chapter prepended above (unchanged at the start of the book).
    static func prependingPreviousChapter(to window: Range<Int>, chapterStarts: [Int], count: Int) -> Range<Int> {
        guard window.lowerBound > 0 else { return window }
        let previous = chapterRange(containing: window.lowerBound - 1, chapterStarts: chapterStarts, count: count)
        return previous.lowerBound..<window.upperBound
    }

    /// Whether the previous chapter should be prepended: the block at the reading line (`top`) is in the window's
    /// first chapter (no spare chapter above it), and the book has chapters before it.
    static func needsPrepend(top: Int?, window: Range<Int>, chapterStarts: [Int], count: Int) -> Bool {
        guard let top, window.lowerBound > 0, window.contains(top) else { return false }
        return chapterRange(containing: top, chapterStarts: chapterStarts, count: count).lowerBound == window.lowerBound
    }

    /// Whether a prepend cannot wait for the scroll to be idle: `top` is within `prependMargin` blocks of the window's
    /// first block, where a fling would otherwise reach the edge and bounce.
    static func prependIsUrgent(top: Int?, window: Range<Int>) -> Bool {
        guard let top, window.lowerBound > 0, window.contains(top) else { return false }
        return top - window.lowerBound < prependMargin
    }

    /// `window` without the chapters far below the reader: it keeps the chapter being read (`top`'s), the one after
    /// it, and at least `minimumBelow` blocks after `top`. Dropping blocks below the screen never moves it.
    static func trimmedBelow(_ window: Range<Int>, readingAt top: Int, chapterStarts: [Int], count: Int) -> Range<Int> {
        guard window.contains(top) else { return window }
        let current = chapterRange(containing: top, chapterStarts: chapterStarts, count: count)
        var keep = current.upperBound
        if keep < count {
            keep = chapterRange(containing: keep, chapterStarts: chapterStarts, count: count).upperBound
        }
        while keep < count && keep - top < minimumBelow {
            keep = chapterRange(containing: keep, chapterStarts: chapterStarts, count: count).upperBound
        }
        guard keep < window.upperBound else { return window }
        return window.lowerBound..<keep
    }

    /// `window` with the next chapter appended below (unchanged at the end of the book).
    static func appendingNextChapter(to window: Range<Int>, chapterStarts: [Int], count: Int) -> Range<Int> {
        guard window.upperBound < count else { return window }
        let next = chapterRange(containing: window.upperBound, chapterStarts: chapterStarts, count: count)
        return window.lowerBound..<next.upperBound
    }

    /// Whether the next chapter should be appended: one of the window's last `appendMargin` blocks is laid out
    /// (`lastLaidOut`: the highest block index with a measured frame) and the book goes on.
    static func needsAppend(lastLaidOut: Int?, window: Range<Int>, count: Int) -> Bool {
        guard let lastLaidOut, window.upperBound < count else { return false }
        return lastLaidOut >= window.upperBound - appendMargin
    }

    /// The window `target` needs for a hand-back or another move that must not rebuild what is on screen: the same
    /// start, extended below (whole chapters) until it holds `target` with `minimumBelow` blocks after it. Nil when
    /// the target is above the window (only a reload can show it).
    static func extended(_ window: Range<Int>, toHold target: Int, chapterStarts: [Int], count: Int) -> Range<Int>? {
        guard target >= window.lowerBound else { return nil }
        var upper = window.upperBound
        while upper < count && upper - target < minimumBelow {
            upper = chapterRange(containing: upper, chapterStarts: chapterStarts, count: count).upperBound
        }
        return window.lowerBound..<max(upper, window.upperBound)
    }
}

/// Where the reader's rows are, for a plain (non-lazy) stack: each row's frame in the stack's own space,
/// recorded when it changes (only on layout: scrolling moves the stack, not the rows in it), and the stack's frame
/// in the scroll view's space and on screen, recorded as it scrolls. The frames of the rows near the viewport follow
/// from the two, so nothing per row runs on each scroll frame. Not observed: the view reports from it.
final class BlockFrameStore {
    /// Row frames in the stack's coordinate space, by block index.
    var rows: [Int: CGRect] = [:]
    /// The stack's frame in the scroll view's coordinate space.
    var stackInScroll: CGRect?
    /// The stack's top on screen (global y).
    var stackScreenMinY: CGFloat?

    /// The frames (scroll-view space, as `BlockFramesKey` reported them) of the rows of `window` within one
    /// viewport height (at least 100 pt) above or below the viewport. Empty until the stack has been placed.
    func frames(window: Range<Int>, viewportHeight: CGFloat) -> [Int: BlockFrame] {
        guard let stack = stackInScroll, let screenTop = stackScreenMinY else { return [:] }
        let margin = max(viewportHeight, 100)
        var result: [Int: BlockFrame] = [:]
        for (index, row) in rows where window.contains(index) {
            let minY = stack.minY + row.minY
            let maxY = stack.minY + row.maxY
            guard maxY > -margin, minY < viewportHeight + margin else { continue }
            result[index] = BlockFrame(minY: minY, maxY: maxY, width: row.width, minX: stack.minX + row.minX,
                                       screenMinY: screenTop + row.minY)
        }
        return result
    }
}
