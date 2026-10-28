import Foundation
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

    /// Font size multiplier relative to the user's base size.
    static func scale(for style: BlockStyle) -> Double {
        switch style {
        case .heading1: return 1.35
        case .heading2: return 1.25
        case .heading3: return 1.15
        case .heading4, .heading5, .heading6: return 1.05
        case .paragraph, .quote, .listItem: return 1.0
        }
    }

    static func isHeading(_ style: BlockStyle) -> Bool {
        switch style {
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6: return true
        default: return false
        }
    }
}
