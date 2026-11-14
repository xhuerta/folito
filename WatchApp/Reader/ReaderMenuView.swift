import SwiftUI
import ReaderCore

/// Sheet shown from the reader: text size, dictionary and chapter index.
struct ReaderMenuView: View {
    @ObservedObject var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var typography: TypographyModel
    /// Why the sync glyph on the options button is showing (offline, account rejected, server error), shown
    /// at the top of the menu; nil when there is nothing to explain.
    var syncNote: String? = nil
    /// Asks the reader to open the word lookup for the block at the top of the screen once this sheet is gone.
    var onLookup: () -> Void = {}
    @AppStorage(ReaderSettings.showTimeRemainingKey) private var showTimeRemaining = true
    /// True while "Go to Synced Position" is fetching the remote position.
    @State private var fetchingSyncedPosition = false
    /// Why "Go to Synced Position" did not jump (no position on the service, or it could not be reached).
    @State private var syncedPositionNote: Text?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    // Top of the menu, not over the page: the reading view keeps every point for the text.
                    // The percentage always shows; the time left joins it when it is on and known.
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            ReadingProgressLine(text: model.progressText())
                            if showTimeRemaining, let remaining = model.timeRemaining {
                                TimeRemainingLine(value: remaining)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                    if let syncNote {
                        Section {
                            Label {
                                Text(syncNote).font(.footnote)
                            } icon: {
                                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.tint)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("syncNote")
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
                    // Sync is forward only, like Readest and KOReader (#112): the open-time prompt only offers a
                    // position that is ahead. This is the way back to one that is behind. Hidden while sync is off.
                    if model.canGoToSyncedPosition {
                        Section("Sync") {
                            Button {
                                goToSyncedPosition()
                            } label: {
                                Label("Go to Synced Position", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(fetchingSyncedPosition)
                            .accessibilityLabel(Text("Go to Synced Position"))
                            .accessibilityHint(Text("Jumps to the position saved on the sync service, even if it is earlier in the book.",
                                                    comment: "VoiceOver hint of 'Go to Synced Position' in the reader menu"))
                            .accessibilityIdentifier("goToSyncedPositionButton")
                            if let syncedPositionNote {
                                syncedPositionNote
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("syncedPositionNote")
                            }
                        }
                    }
                    Section("Chapters") {
                        let current = currentRow
                        ForEach(Array(model.flat.contents.enumerated()), id: \.offset) { offset, row in
                            ContentsRowView(row: row, isCurrent: offset == current) {
                                if let start = row.startIndex {
                                    model.jump(to: start, characterOffset: row.characterOffset)
                                    dismiss()
                                }
                            }
                            .id(offset)
                        }
                    }
                }
                .onAppear { scrollToCurrentChapter(proxy) }
            }
            // "Options", not "Contents": the sheet holds the text size, typography and the dictionary as well as the
            // chapters, and it is opened from the Reading Options button.
            .navigationTitle(Text("Options", comment: "Title of the reading options sheet opened from the reader"))
            .navigationDestination(for: SettingsRoute.self) { $0.destination }
        }
    }

    /// Row of the chapter list marked as the current one (nil in front matter before the first TOC entry).
    private var currentRow: Int? {
        model.flat.currentContentsRow(at: model.currentIndex, characterOffset: model.currentOffset)
    }

    /// With a TOC (books can list hundreds of entries), the list opens on the current entry. Not while it is one
    /// of the first rows, which a short scroll reaches: the sheet then opens at its top, with the progress and the
    /// text size in view. Books without a TOC open at the top as before.
    private func scrollToCurrentChapter(_ proxy: ScrollViewProxy) {
        guard model.flat.toc != nil, let row = currentRow, row >= Self.autoScrollMinimumRow else { return }
        proxy.scrollTo(row, anchor: .center)
    }

    static let autoScrollMinimumRow = 3

    private func goToSyncedPosition() {
        fetchingSyncedPosition = true
        syncedPositionNote = nil
        Task {
            let result = await model.goToSyncedPosition()
            fetchingSyncedPosition = false
            switch result {
            case .jumped:
                dismiss()
            case .alreadyThere:
                syncedPositionNote = Text("Already at the synced position.",
                                          comment: "Shown under 'Go to Synced Position' when the reader already is at the position the sync service has")
            case .noPosition:
                syncedPositionNote = Text("No synced position for this book yet.",
                                          comment: "Shown under 'Go to Synced Position' when the sync service has no position for the book")
            case .failed:
                syncedPositionNote = Text("Couldn't reach the sync service. Try again later.",
                                          comment: "Shown under 'Go to Synced Position' when fetching the position failed")
            }
        }
    }
}

/// A row of the chapter list: a chapter (marked with the bookmark glyph when it is the current one), or a group
/// header above the chapters ("Part One") in a TOC. VoiceOver reads the group with an indented chapter
/// ("Chapter 3, in Part One") and says "selected" for the current row.
struct ContentsRowView: View {
    let row: FlatBook.ContentsRow
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        if row.kind == .group, row.startIndex == nil {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenTitle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("chapterGroup")
        } else {
            Button(action: action) { label }
                .accessibilityLabel(spokenTitle)
                // The bookmark glyph is visual only: VoiceOver says "selected" instead.
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityAddTraits(row.kind == .group ? .isHeader : [])
                .accessibilityIdentifier(row.kind == .group ? "chapterGroup" : "chapterButton")
        }
    }

    private var label: some View {
        HStack {
            title
            if isCurrent {
                Spacer()
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, row.isIndented ? 8 : 0)
    }

    @ViewBuilder private var title: some View {
        if row.kind == .group {
            Text(row.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        } else {
            Text(row.title).lineLimit(3)
        }
    }

    private var spokenTitle: Text {
        guard row.isIndented, let group = row.groupTitle else { return Text(row.title) }
        return Text("\(row.title), in \(group)",
                    comment: "VoiceOver label of a chapter in the reader's chapter list, with the part it belongs to, e.g. 'Chapter 3, in Part One'")
    }
}

/// "43% read": how far into the book the reader is, worded as in the book's Library row. VoiceOver reads it
/// as it is ("43 percent read"), as its own element above the time left.
struct ReadingProgressLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("readingProgress")
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

/// Reader body size stepper used in the reader menu, in Settings and in Typography. VoiceOver reads it as
/// "Text Size, 16 points" and adjusts it with swipe up / down (it is exposed as a Stepper).
struct TextSizeStepper: View {
    @EnvironmentObject private var typography: TypographyModel

    var body: some View {
        let size = Int(typography.value.fontSize)
        SettingStepperRow(title: Text("Text Size")) {
            CrownFreeStepper(value: typography.binding(\.fontSize), in: ReaderTypography.fontSizeRange, step: 1) {
                SettingStepperValue(Text("\(size) pt", comment: "Reader text size in typographic points, e.g. '16 pt'"))
            }
            .accessibilityLabel(Text("Text Size"))
            .accessibilityValue(Text("\(size) points", comment: "VoiceOver value of the reader text size"))
            .accessibilityIdentifier("textSizeStepper")
        }
    }
}

/// A − value + control that looks like the watch Stepper but never takes the Digital Crown.
///
/// The system Stepper is crown-focusable: while the crown scrolled a List past it (the reader menu on the way
/// to the chapters, Settings, Typography), the Stepper grabbed the crown and changed the value instead. Here
/// the − and + are plain buttons, which the crown ignores, so the crown only scrolls the list. VoiceOver still
/// gets a real, adjustable Stepper through `accessibilityRepresentation` (swipe up / down), so its label,
/// value, identifier and element type are unchanged.
struct CrownFreeStepper<Content: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @ViewBuilder var label: Content
    /// Height and width of the − / + tap targets: the watchOS minimum, scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 40

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, @ViewBuilder label: () -> Content) {
        _value = value
        self.range = range
        self.step = step
        self.label = label()
    }

    var body: some View {
        HStack(spacing: 2) {
            button(-1)
            label.frame(maxWidth: .infinity)
            button(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityRepresentation {
            Stepper(value: $value, in: range, step: step) { label }
        }
    }

    private func button(_ direction: Double) -> some View {
        let target = Self.stepped(value, by: direction * step, in: range)
        return Button { value = target } label: {
            Image(systemName: direction < 0 ? "minus" : "plus")
                .font(.body.weight(.semibold))
                .frame(width: buttonSize, height: buttonSize)
                .background(Circle().fill(.quaternary))
                .contentShape(Circle())
        }
        // Plain: in a List row, each button keeps its own tap area instead of the row firing both.
        .buttonStyle(.plain)
        .disabled(target == value)
        .accessibilityHidden(true)
    }

    /// `value` moved by `delta` and clamped to `range`.
    static func stepped(_ value: Double, by delta: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value + delta, range.lowerBound), range.upperBound)
    }
}

/// A watch Stepper row that stays legible at every Dynamic Type size. The watch Stepper lays its label out in
/// the narrow column between the − and + buttons, so a title there ("Tamaño del texto" at a large text size)
/// broke letter by letter. The title goes on its own full-width line above the control instead, and the
/// Stepper only carries the short value. The title is hidden from VoiceOver: the Stepper's own label says it.
struct SettingStepperRow<Control: View>: View {
    let title: Text
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            control
        }
    }
}

/// The value shown between the − and + buttons of a `SettingStepperRow`: one line, shrunk rather than
/// wrapped when it does not fit, so it is never broken mid-word.
struct SettingStepperValue: View {
    let text: Text

    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
    }
}
