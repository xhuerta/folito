import SwiftUI
import ReaderCore

/// A footnote or endnote, opened from its marker in the text (#66). The note's text travels with the reference
/// in the processed book, so the chapter that holds it is never loaded and the reading position never moves:
/// closing the sheet returns to the same line.
///
/// The note is drawn in the reader's body typography (font family, size, weight, line spacing, tracking and
/// alignment of a paragraph), so it reads like the book's text rather than in the larger system body font.
/// Like the reader, it follows Dynamic Type only with "Match System Text Size", and Bold Text always. The
/// title ("Footnote 3") stays a small secondary label. VoiceOver reads the title and the note as one
/// element; the crown and touch scroll long notes.
struct NoteSheet: View {
    let note: NoteReference
    @EnvironmentObject private var typography: TypographyModel
    private var readerAccessibility = ReaderAccessibilityReader()

    init(note: NoteReference) {
        self.note = note
    }

    /// The reader's body-text font, used for the note's text.
    static func bodyFont(in style: ReaderRenderStyle) -> Font {
        style.font(for: .paragraph)
    }

    var body: some View {
        // Same style the reader resolves for the device's accessibility state (cached by the model).
        let style = typography.style(for: readerAccessibility.value)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.localizedTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Text(note.text)
                    .tracking(style.typography.tracking)
                    .font(Self.bodyFont(in: style))
                    .lineSpacing(style.typography.lineSpacing)
                    .multilineTextAlignment(style.alignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: style.frameAlignment)
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
