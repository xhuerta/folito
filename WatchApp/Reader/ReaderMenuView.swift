import SwiftUI
import ReaderCore

/// Sheet shown from the reader: font size and chapter index.
struct ReaderMenuView: View {
    @ObservedObject var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var typography: TypographyModel
    /// Asks the reader to open the word lookup for the block at the top of the screen once this sheet is gone.
    var onLookup: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                Section("Text") {
                    Stepper(value: typography.binding(\.fontSize), in: ReaderTypography.fontSizeRange, step: 1) {
                        Text("\(Int(typography.value.fontSize)) pt")
                    }
                    NavigationLink("Typography") { TypographyEditorView() }
                }
                Section("Dictionary") {
                    Button {
                        onLookup()
                        dismiss()
                    } label: {
                        Label("Look up a word", systemImage: "character.book.closed")
                    }
                }
                Section("Chapters") {
                    let current = model.flat.chapterRefIndex(containing: model.currentIndex)
                    ForEach(Array(model.flat.chapterRefs.enumerated()), id: \.offset) { offset, ref in
                        Button {
                            model.jump(to: ref.startIndex)
                            dismiss()
                        } label: {
                            HStack {
                                Text(ref.title).lineLimit(2)
                                if offset == current {
                                    Spacer()
                                    Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Contents")
        }
    }
}
