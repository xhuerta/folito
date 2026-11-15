import Foundation
import SwiftUI
import ReaderCore

/// Converts `StyleSpan` UTF-16 ranges into `AttributedString` runs and maps block styles to typography.
enum BlockText {
    struct Run: Equatable {
        let range: Range<String.Index>
        let bold: Bool
        let italic: Bool
    }

    /// Valid, clamped runs for `spans` over `text`. Spans outside the text or splitting a
    /// unicode scalar are dropped/clamped rather than crashing.
    static func runs(text: String, spans: [StyleSpan]) -> [Run] {
        let utf16Count = text.utf16.count
        var result: [Run] = []
        for span in spans where (span.bold || span.italic) && span.length > 0 {
            let start = max(0, span.location)
            let end = min(utf16Count, span.location + span.length)
            guard start < end else { continue }
            guard let range = Range(NSRange(location: start, length: end - start), in: text) else { continue }
            result.append(Run(range: range, bold: span.bold, italic: span.italic))
        }
        return result
    }

    static func attributed(text: String, spans: [StyleSpan]) -> AttributedString {
        var attr = AttributedString(text)
        for run in runs(text: text, spans: spans) {
            guard let r = Range<AttributedString.Index>(run.range, in: attr) else { continue }
            var intent = attr[r].inlinePresentationIntent ?? []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            attr[r].inlinePresentationIntent = intent
        }
        return attr
    }

    /// Valid, clamped ranges of the note markers (#66) in `text`; invalid ranges are dropped.
    static func noteRanges(text: String, notes: [NoteReference]) -> [Range<String.Index>] {
        let utf16Count = text.utf16.count
        var result: [Range<String.Index>] = []
        for note in notes where note.length > 0 {
            let start = max(0, note.location)
            let end = min(utf16Count, note.location + note.length)
            guard start < end, let range = Range(NSRange(location: start, length: end - start), in: text) else { continue }
            result.append(range)
        }
        return result
    }

    /// `attributed` with its note markers underlined in `color`, so they stand out from the text by shape as
    /// well as colour. Returns `attributed` unchanged for a block without notes.
    static func markingNotes(_ attributed: AttributedString, text: String, notes: [NoteReference],
                             color: Color) -> AttributedString {
        guard !notes.isEmpty else { return attributed }
        var marked = attributed
        for range in noteRanges(text: text, notes: notes) {
            guard let r = Range<AttributedString.Index>(range, in: marked) else { continue }
            // Typed values pick the SwiftUI attributes (UIKit's take UIColor / NSUnderlineStyle).
            let underline: Text.LineStyle = Text.LineStyle(pattern: .solid, color: color)
            marked[r].foregroundColor = color
            marked[r].underlineStyle = underline
        }
        return marked
    }

    /// Font size multiplier relative to the user's base size (headings at default heading scale).
    static func scale(for style: BlockStyle) -> Double { style.baseScale }

    static func isHeading(_ style: BlockStyle) -> Bool { style.isHeading }
}
