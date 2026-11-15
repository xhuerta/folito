import SwiftUI
import ReaderCore

/// A footnote or endnote, opened from its marker in the text (#66). The note's text travels with the reference
/// in the processed book, so the chapter that holds it is never loaded and the reading position never moves:
/// closing the sheet returns to the same line.
///
/// System fonts, so the note follows Dynamic Type (and Bold Text) like other sheets. VoiceOver reads the title
/// ("Footnote 3") and the note as one element; the crown and touch scroll long notes.
struct NoteSheet: View {
    let note: NoteReference

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.localizedTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(note.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("noteText")
        }
    }
}

/// VoiceOver actions that open the notes referenced in a block ("Footnote 3"), one per reference. A block is a
/// single text element, so the markers cannot be elements of their own; the actions rotor reaches them.
struct NoteAccessibilityActions: ViewModifier {
    let notes: [NoteReference]
    let open: @MainActor (NoteReference) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if notes.isEmpty {
            content
        } else {
            content.accessibilityActions {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Button(note.localizedTitle) { open(note) }
                }
            }
        }
    }
}
