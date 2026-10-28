import SwiftUI
import ReaderCore

/// Sheet: pick a word of a paragraph with the Digital Crown, then look it up.
///
/// watchOS cannot select text in SwiftUI `Text` nor show the system dictionary, so the crown moves a
/// cursor over the paragraph's words instead (the +/- buttons do the same without the crown).
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
                Text("No words in this paragraph.").foregroundStyle(.secondary)
            }
        }
    }
}

struct WordPickerView: View {
    @ObservedObject var model: WordLookupModel

    var body: some View {
        VStack(spacing: 6) {
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
            Text("\(model.index + 1) / \(model.tokens.count)")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.index == 0)
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.index >= model.tokens.count - 1)
            }
            NavigationLink {
                DefinitionView(model: model)
            } label: {
                Label("Look up", systemImage: "character.book.closed")
            }
            .buttonStyle(.borderedProminent)
        }
        .focusable()
        .digitalCrownRotation($model.cursor, from: 0, through: model.maxCursor, by: 1,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .navigationTitle("Word")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func highlighted(_ c: WordContext) -> AttributedString {
        var result = AttributedString((c.hasMoreBefore ? "\u{2026}" : "") + c.before)
        var word = AttributedString(c.word)
        word.backgroundColor = .yellow
        word.foregroundColor = .black
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
                VStack { ProgressView(); Text("Looking up\u{2026}").font(.footnote).foregroundStyle(.secondary) }
            case .failed(let error):
                ScrollView {
                    VStack(spacing: 8) {
                        Image(systemName: icon(for: error)).font(.title3).foregroundStyle(.secondary)
                        Text(error.userMessage).font(.footnote).multilineTextAlignment(.center)
                        if error != .notFound {
                            Button("Retry") { Task { await model.lookup() } }
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
                    if let p = entry.pronunciation { Text(p).font(.footnote).foregroundStyle(.secondary) }
                    if entry.word.lowercased() != requested.lowercased() {
                        Text("Form of \u{201C}\(entry.word)\u{201D}").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(entry.meanings.enumerated()), id: \.offset) { _, meaning in
                Section(meaning.partOfSpeech.capitalized) {
                    ForEach(Array(meaning.senses.enumerated()), id: \.offset) { n, sense in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(n + 1). \(sense.definition)").font(.footnote)
                            ForEach(sense.examples, id: \.self) { example in
                                Text("\u{201C}\(example)\u{201D}").font(.caption2).italic().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Text(entry.source).font(.caption2).foregroundStyle(.secondary)
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
