import SwiftUI
import ReaderCore

/// Sheet: pick a word of a paragraph with the Digital Crown, then look it up.
///
/// watchOS cannot select text in SwiftUI `Text` nor show the system dictionary, so the crown moves a
/// cursor over the paragraph's words instead. The previous / next buttons and the VoiceOver adjustable
/// action (swipe up / down) do the same without the crown.
struct WordLookupSheet: View {
    @StateObject private var model: WordLookupModel

    init(text: String, language: String?, provider: DictionaryProviding) {
        _model = StateObject(wrappedValue: WordLookupModel(text: text, language: language, provider: provider))
    }

    var body: some View {
        NavigationStack {
            if model.hasWords {
                WordPickerView(model: model)
            } else {
                ContentUnavailableView("No Words", systemImage: "character.book.closed",
                                       description: Text("This paragraph has no words to look up."))
            }
        }
    }
}

struct WordPickerView: View {
    @ObservedObject var model: WordLookupModel

    var body: some View {
        // Scrolls at large text sizes; the crown stays on the word cursor (focused view) while the page
        // can still be scrolled by touch.
        ScrollView {
            VStack(spacing: 8) {
                cursor
                HStack {
                    Button { model.step(-1) } label: {
                        Label("Previous Word", systemImage: "chevron.backward")
                            .labelStyle(.iconOnly)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canStepBack)
                    Button { model.step(1) } label: {
                        Label("Next Word", systemImage: "chevron.forward")
                            .labelStyle(.iconOnly)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canStepForward)
                }
                NavigationLink {
                    DefinitionView(model: model)
                } label: {
                    Label("Look Up", systemImage: "character.book.closed")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(Text("Shows the definition of \(model.currentWord)."))
            }
        }
        .navigationTitle("Word")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The selected word in its context. One adjustable VoiceOver element: it announces the word and its
    /// position, and swiping up / down moves to the next / previous word.
    private var cursor: some View {
        VStack(spacing: 4) {
            Text(model.currentWord)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let context = model.context {
                Text(Self.highlighted(context))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            Text(model.positionText)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .focusable()
        .digitalCrownRotation($model.cursor, from: 0, through: model.maxCursor, by: 1,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Selected word"))
        .accessibilityValue(Text(model.accessibilityValue))
        .accessibilityHint(Text("Swipe up or down to choose another word."))
        .accessibilityAdjustableAction { model.adjust($0) }
    }

    static func highlighted(_ c: WordContext) -> AttributedString {
        var result = AttributedString((c.hasMoreBefore ? "\u{2026}" : "") + c.before)
        var word = AttributedString(c.word)
        // Black on yellow: 19.6:1. Bold too, so the cue does not rely on colour alone.
        word.backgroundColor = .yellow
        word.foregroundColor = .black
        word.inlinePresentationIntent = .stronglyEmphasized
        result += word
        result += AttributedString(c.after + (c.hasMoreAfter ? "\u{2026}" : ""))
        return result
    }
}

/// Definition(s) of the selected word: loading / error / scrollable result.
struct DefinitionView: View {
    @ObservedObject var model: WordLookupModel

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView {
                    Text("Looking Up\u{2026}")
                }
            case .failed(let error):
                ScrollView {
                    VStack(spacing: 8) {
                        Image(systemName: icon(for: error))
                            .font(.title3).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(WatchMessages.dictionary(error))
                            .font(.footnote).multilineTextAlignment(.center)
                        if error != .notFound {
                            Button("Try Again") { Task { await model.lookup() } }
                        }
                    }
                }
            case .loaded(let entry):
                EntryList(entry: entry, requested: model.currentWord)
            }
        }
        .navigationTitle(model.currentWord)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.lookup() }
    }

    private func icon(for error: DictionaryError) -> String {
        switch error {
        case .offline: return "wifi.slash"
        case .notFound: return "questionmark.circle"
        case .rateLimited: return "hourglass"
        default: return "exclamationmark.triangle"
        }
    }
}

struct EntryList: View {
    let entry: DictionaryEntry
    let requested: String

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.word).font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let p = entry.pronunciation { Text(p).font(.footnote).foregroundStyle(.secondary) }
                    if entry.word.lowercased() != requested.lowercased() {
                        Text("Form of \u{201C}\(entry.word)\u{201D}", comment: "Shown when the dictionary returned the base form of the selected word")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(entry.meanings.enumerated()), id: \.offset) { _, meaning in
                Section(meaning.partOfSpeech.capitalized) {
                    ForEach(Array(meaning.senses.enumerated()), id: \.offset) { n, sense in
                        // One VoiceOver element per sense: number, definition and examples.
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(n + 1). \(sense.definition)").font(.footnote)
                            ForEach(sense.examples, id: \.self) { example in
                                Text(verbatim: "\u{201C}\(example)\u{201D}").font(.caption2).italic().foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Section {
                Text("Source: \(entry.source)", comment: "Dictionary attribution, e.g. 'Source: Wiktionary'")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Picker") {
    WordLookupSheet(text: "It was a bright cold day in April, and the clocks were striking thirteen.",
                    language: "en", provider: MockDictionaryProvider.sample)
}

#Preview("Entry") {
    NavigationStack {
        EntryList(entry: MockDictionaryProvider.sample.entries["run"]!, requested: "running")
    }
}
