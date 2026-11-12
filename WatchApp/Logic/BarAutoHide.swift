import Foundation
import CoreGraphics

/// Safari-style auto-hide of the reader's navigation bar (#106). Pure; the view feeds it scroll offsets,
/// taps and timer ticks, and hides the bar while `isHidden` is true.
///
/// - Scrolling down through the text by `hideDistance` hides the bar; scrolling back up by `showDistance`
///   (measured from the furthest point reached) shows it again.
/// - A tap on the text while the bar is hidden shows it; it hides again `tapRevealDuration` seconds later
///   unless the reader scrolled back up in the meantime.
/// - At the start of the book (`minHideOffset`), and always with VoiceOver on, the bar stays visible.
/// - A single offset change larger than `jumpDistance` is a programmatic jump (restore, chapter, remote
///   position), not reading: it re-anchors without hiding, so a book never opens with the bar hidden.
/// - After the bar hides or shows, offsets are ignored for `settleDuration` while the safe area animates,
///   so the inset change itself can never flip the bar back.
struct BarAutoHide: Equatable {
    static let hideDistance: CGFloat = 24
    static let showDistance: CGFloat = 36
    static let topZone: CGFloat = 8
    /// Never hides this close to the start of the book: more than the bar's height, so the inset change of
    /// hiding cannot bring the offset back into `topZone`.
    static let minHideOffset: CGFloat = 60
    static let jumpDistance: CGFloat = 400
    static let settleDuration: TimeInterval = 0.6
    static let tapRevealDuration: TimeInterval = 3

    private(set) var isHidden = false
    /// Where the current run of scrolling in one direction started (furthest point reached).
    private var anchor: CGFloat?
    private var lastOffset: CGFloat = 0
    private var settleUntil: Date = .distantPast
    private(set) var tapRevealUntil: Date?

    /// `offset`: how far the text is scrolled, 0 at the start of the book, growing while reading forward.
    mutating func scrolled(to offset: CGFloat, at now: Date, voiceOver: Bool) {
        defer { lastOffset = offset }
        if voiceOver {
            set(hidden: false, at: now, offset: offset)
            anchor = offset
            return
        }
        guard now >= settleUntil, let start = anchor, abs(offset - lastOffset) <= Self.jumpDistance else {
            anchor = offset
            return
        }
        if offset <= Self.topZone {
            set(hidden: false, at: now, offset: offset)
            anchor = offset
            return
        }
        let delta = offset - start
        if isHidden {
            if -delta >= Self.showDistance {
                set(hidden: false, at: now, offset: offset)
            } else if delta > 0 {
                anchor = offset
            }
        } else {
            if delta >= Self.hideDistance, offset > Self.minHideOffset {
                set(hidden: true, at: now, offset: offset)
            } else if delta < 0 {
                anchor = offset
            }
        }
    }

    /// A single tap on the text. Returns true when the tap was used to show the hidden bar (the caller
    /// then skips its usual tap action, the word lookup).
    mutating func tapped(at now: Date, voiceOver: Bool) -> Bool {
        guard isHidden, !voiceOver else { return false }
        set(hidden: false, at: now, offset: lastOffset)
        tapRevealUntil = now.addingTimeInterval(Self.tapRevealDuration)
        return true
    }

    /// Called when the tap reveal may have expired: hides the bar again if it is still showing only
    /// because of the tap.
    mutating func tick(at now: Date, voiceOver: Bool) {
        guard let until = tapRevealUntil, now >= until else { return }
        tapRevealUntil = nil
        guard !voiceOver, lastOffset > Self.minHideOffset else { return }
        set(hidden: true, at: now, offset: lastOffset)
    }

    /// Shows the bar (VoiceOver turned on, a sheet opened).
    mutating func show(at now: Date) {
        set(hidden: false, at: now, offset: lastOffset)
    }

    private mutating func set(hidden: Bool, at now: Date, offset: CGFloat) {
        // Scrolling (in either direction) cancels a pending tap reveal: from then on the scroll rules decide.
        tapRevealUntil = nil
        guard hidden != isHidden else { return }
        isHidden = hidden
        anchor = offset
        settleUntil = now.addingTimeInterval(Self.settleDuration)
    }
}

/// The reading line: the top of the visible area with the navigation bar shown (#116 saves the line at
/// that edge and restores relative to it). While the bar is auto-hidden the scroll view's top inset
/// shrinks to 0, but the reading line must not move with it, or hiding the bar would save a position a
/// couple of lines earlier and showing it would move it back. So the line only follows the measured inset
/// while the bar is shown, and never moves up because of the bar's show animation (intermediate insets).
enum ReadingLine {
    static func updated(current: CGFloat, measured: CGFloat, barShown: Bool) -> CGFloat {
        barShown ? max(current, measured) : current
    }
}
