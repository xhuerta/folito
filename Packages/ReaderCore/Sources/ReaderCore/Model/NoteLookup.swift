import Foundation

extension NoteReference {
    /// Character (Swift `Character`) range of the marker in `text`; nil when the UTF-16 range is not valid there.
    public func characterRange(in text: String) -> Range<Int>? {
        let utf16 = text.utf16
        guard location >= 0, length > 0, location + length <= utf16.count else { return nil }
        let start16 = utf16.index(utf16.startIndex, offsetBy: location)
        let end16 = utf16.index(start16, offsetBy: length)
        guard let start = start16.samePosition(in: text), let end = end16.samePosition(in: text) else { return nil }
        let lower = text.distance(from: text.startIndex, to: start)
        return lower..<(lower + text.distance(from: start, to: end))
    }
}

extension Block {
    /// Characters a tap may miss a note marker by and still open it. The tap's character offset is an
    /// estimate (`TapPosition`), and a marker is often a single superscript digit.
    public static let noteTapTolerance = 3

    /// The note reference closest to `characterOffset` (a tap), if one is within `tolerance` characters.
    public func noteReference(nearCharacterOffset characterOffset: Int,
                              tolerance: Int = Block.noteTapTolerance) -> NoteReference? {
        guard let notes, !notes.isEmpty else { return nil }
        var best: (note: NoteReference, distance: Int)?
        for note in notes {
            guard let range = note.characterRange(in: text) else { continue }
            let distance: Int
            if characterOffset < range.lowerBound {
                distance = range.lowerBound - characterOffset
            } else if characterOffset >= range.upperBound {
                distance = characterOffset - range.upperBound + 1
            } else {
                distance = 0
            }
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance { best = (note, distance) }
        }
        return best?.note
    }
}
