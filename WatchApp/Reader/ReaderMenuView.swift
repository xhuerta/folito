import SwiftUI

/// Sheet shown from the reader: font size and chapter index.
struct ReaderMenuView: View {
    @ObservedObject var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReaderSettings.fontSizeKey) private var fontSize = ReaderSettings.defaultFontSize

    var body: some View {
        NavigationStack {
            List {
                Section("Text size") {
                    Stepper(value: $fontSize, in: ReaderSettings.minFontSize...ReaderSettings.maxFontSize, step: 1) {
                        Text("\(Int(ReaderSettings.clampFontSize(fontSize))) pt")
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
