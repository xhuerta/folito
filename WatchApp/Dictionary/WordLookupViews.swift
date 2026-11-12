import SwiftUI
import ReaderCore

/// Sheet: pick a word of a paragraph with the Digital Crown, then look it up.
///
/// watchOS cannot select text in SwiftUI `Text` nor show the system dictionary, so the crown moves a
/// cursor over the paragraph's words instead. The cursor starts on the tapped word (estimated from the
/// tap position, see `TapPosition`). The small previous / next buttons and the VoiceOver adjustable
/// action (swipe up / down) move it without the crown.
struct WordLookupSheet: View {
    @StateObject private var model: WordLookupModel

    init(text: String, language: String?, provider: DictionaryProviding, initialCharacterOffset: Int? = nil) {
        _model = StateObject(wrappedValue: WordLookupModel(text: text, language: language, provider: provider,
                                                           initialCharacterOffset: initialCharacterOffset))
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
    /// Side of the round previous / next buttons: the watchOS minimum tap target, scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var arrowSize: CGFloat = 40

    var body: some View {
        // Scrolls at large text sizes; the crown stays on the word cursor (focused view) while the page
        // can still be scrolled by touch.
        ScrollView {
            VStack(spacing: 6) {
                cursor
                // One compact row (previous, Look Up, next) so the word and its context keep the screen
                // on a 40-45 mm watch. At large text sizes the row does not fit and the buttons stack.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        arrow(-1)
                        lookUpButton.layoutPriority(1)
                        arrow(1)
                    }
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            arrow(-1)
                            Spacer(minLength: 0)
                            arrow(1)
                        }
                        lookUpButton
                    }
                }
            }
        }
        .navigationTitle("Word")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func arrow(_ delta: Int) -> some View {
        Button { model.step(delta) } label: {
            Label(delta < 0 ? "Previous Word" : "Next Word",
                  systemImage: delta < 0 ? "chevron.backward" : "chevron.forward")
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .frame(width: arrowSize, height: arrowSize)
        .disabled(delta < 0 ? !model.canStepBack : !model.canStepForward)
    }

    private var lookUpButton: some View {
        NavigationLink {
            DefinitionView(model: model)
        } label: {
            Text("Look Up")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .frame(minHeight: arrowSize)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHint(Text("Shows the definition of \(model.currentWord)."))
    }

    /// The selected word in its context. One adjustable VoiceOver element: it announces the word and its
    /// position, and swiping up / down moves to the next / previous word.
    private var cursor: some View {
        VStack(spacing: 2) {
            Text(model.currentWord)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let context = model.context {
                Text(Self.highlighted(context))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
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
        // Black on system yellow: about 15:1. Bold too, so the cue does not rely on colour alone.
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
                        if error == .unreadable {
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
        case .noDictionary, .noDictionaryForLanguage: return "character.book.closed"
        case .notFound: return "questionmark.circle"
        case .unreadable: return "exclamationmark.triangle"
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
                Section {
                    ForEach(Array(meaning.senses.enumerated()), id: \.offset) { n, sense in
                        // One VoiceOver element per sense: number, definition, sub-senses and examples.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(n + 1). \(sense.definition)").font(.footnote)
                            ForEach(Array(sense.subsenses.enumerated()), id: \.offset) { _, sub in
                                Text(verbatim: "\u{2022} \(sub)").font(.caption2)
                                    .padding(.leading, 6)
                            }
                            ForEach(sense.examples, id: \.self) { example in
                                Text(verbatim: "\u{201C}\(example)\u{201D}").font(.caption2).italic().foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    // Headings come from the dictionary in its own language ("Noun", "Sustantivo f.").
                    if !meaning.partOfSpeech.isEmpty { Text(verbatim: meaning.partOfSpeech) }
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
    WordLookupSheet(text: "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.",
                    language: "en", provider: MockDictionaryProvider.sample)
}

#Preview("Entry") {
    NavigationStack {
        EntryList(entry: MockDictionaryProvider.sample.entries["run"]!, requested: "running")
    }
}
