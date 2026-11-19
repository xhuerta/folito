import Foundation
import CoreGraphics

/// Which blocks the reader's scroll view holds: the chapter being read, not the whole book (build 49 feedback).
///
/// The reader's `LazyVStack` places blocks it has not measured with estimated heights. With the whole book in it, a
/// jump to block 399 left about 400 estimated blocks above the target; as they were measured the content above
/// shrank (the scroll offset fell from 67955 to 64355 over 13 checks in #181's trace while the target, landed
/// exactly each time, moved up by 230 pt between checks) and the jump never settled. With one chapter loaded, a
/// chapter's start has nothing above it and lands exactly, and anything above a target is at most that chapter.
///
/// - A jump (chapter, bookmark, synced position, opening) to a block outside the window loads the target's chapter,
///   plus the following chapters until at least `minimumBelow` blocks follow the target, so it can reach the top.
/// - Reading forward appends the next chapter below once the last loaded blocks are laid out (`needsAppend`).
///   Appending below never moves what is on screen; nothing is ever inserted or removed above it while reading.
/// - A layout change reloads the current chapter (the scroll view is rebuilt for it anyway): earlier chapters
///   appended while reading are trimmed only then, on a jump or when the book is reopened.
/// - Going back past a chapter's start is a control at the top of the loaded window ("Previous Chapter"), which
///   jumps to the start of the previous chapter.
///
/// Chapters are the book's spine chapters (`FlatBook.chapterStarts`, flat indices). Positions stay global.
enum ChapterWindow {
    /// Blocks a loaded window keeps below a jump's target (about a few screens), so the target can reach the top.
    static let minimumBelow = 12
    /// Append the next chapter once a block this close to the window's end is laid out: well before the reader can
    /// reach the end. With 4, a fling reached the end of the loaded blocks first and the scroll view bounced back
    /// from it (#181's CI: the position went back from block 57 to 54 as "append 60 -> 87" came in).
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

    /// The window a jump to `target` loads: its chapter, extended by the following chapters until at least
    /// `minimumBelow` blocks follow the target (or the book ends).
    static func window(for target: Int, chapterStarts: [Int], count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let chapter = chapterRange(containing: target, chapterStarts: chapterStarts, count: count)
        var upper = chapter.upperBound
        while upper < count && upper - target < minimumBelow {
            upper = chapterRange(containing: upper, chapterStarts: chapterStarts, count: count).upperBound
        }
        return chapter.lowerBound..<upper
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

    /// Where "Previous Chapter" at the top of `window` goes: the start of the chapter before it, nil at the book's
    /// start.
    static func previousChapterStart(before window: Range<Int>, chapterStarts: [Int], count: Int) -> Int? {
        guard window.lowerBound > 0 else { return nil }
        return chapterRange(containing: window.lowerBound - 1, chapterStarts: chapterStarts, count: count).lowerBound
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

/// Where the reader's rows are, for a plain (non-lazy) stack (#181): each row's frame in the stack's own space,
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
