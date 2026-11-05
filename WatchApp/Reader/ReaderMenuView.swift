import SwiftUI
import ReaderCore

/// Sheet shown from the reader: text size, dictionary and chapter index.
struct ReaderMenuView: View {
    @ObservedObject var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var typography: TypographyModel
    /// Asks the reader to open the word lookup for the block at the top of the screen once this sheet is gone.
    var onLookup: () -> Void = {}
    @AppStorage(ReaderSettings.showTimeRemainingKey) private var showTimeRemaining = true

    var body: some View {
        NavigationStack {
            List {
                // Top of the menu, not over the page: the reading view keeps every point for the text.
                if showTimeRemaining, let remaining = model.timeRemaining {
                    Section {
                        TimeRemainingLine(value: remaining)
                    }
                }
                Section("Text") {
                    TextSizeStepper()
                    NavigationLink("Typography", value: SettingsRoute.typography)
                        .accessibilityIdentifier("typographyLink")
                }
                Section("Dictionary") {
                    Button {
                        onLookup()
                        dismiss()
                    } label: {
                        Label("Look Up a Word", systemImage: "character.book.closed")
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
                                Text(ref.title).lineLimit(3)
                                if offset == current {
                                    Spacer()
                                    Image(systemName: "bookmark.fill")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        // The bookmark glyph is visual only: VoiceOver says "selected" instead.
                        .accessibilityAddTraits(offset == current ? .isSelected : [])
                        .accessibilityIdentifier("chapterButton")
                    }
                }
            }
            .navigationTitle("Contents")
            .navigationDestination(for: SettingsRoute.self) { $0.destination }
        }
    }
}

/// "12 min left in chapter · 3 hr, 20 min in book": secondary text that wraps at large Dynamic Type sizes;
/// VoiceOver reads it as full sentences ("12 minutes left in chapter. 3 hours, 20 minutes left in book.").
struct TimeRemainingLine: View {
    let value: ReadingTimeRemaining

    var body: some View {
        Text(TimeRemainingFormat.line(value))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(TimeRemainingFormat.spoken(value)))
            .accessibilityIdentifier("timeRemaining")
    }
}

/// Reader body size stepper used in the reader menu and in Settings. VoiceOver reads it as
/// "Text Size, 16 points" and adjusts it with swipe up / down (Stepper is adjustable).
struct TextSizeStepper: View {
    @EnvironmentObject private var typography: TypographyModel

    var body: some View {
        let size = Int(typography.value.fontSize)
        Stepper(value: typography.binding(\.fontSize), in: ReaderTypography.fontSizeRange, step: 1) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Text Size")
                Text("\(size) pt", comment: "Reader text size in typographic points, e.g. '16 pt'")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text("Text Size"))
        .accessibilityValue(Text("\(size) points", comment: "VoiceOver value of the reader text size"))
        .accessibilityIdentifier("textSizeStepper")
    }
}
