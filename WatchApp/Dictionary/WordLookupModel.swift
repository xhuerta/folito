import Foundation
import SwiftUI
import ReaderCore

/// State of one word-lookup session over a block of text: the cursor (driven by the Digital Crown) and
/// the dictionary request. Platform-light so it can be driven by previews with `MockDictionaryProvider`.
@MainActor
final class WordLookupModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(DictionaryEntry)
        case failed(DictionaryError)
    }

    let text: String
    let tokens: [WordToken]
    private let provider: DictionaryProviding
    private let language: String?

    /// Raw crown value; the selected word is `index`.
    @Published var cursor: Double = 0
    @Published private(set) var state: State = .idle

    init(text: String, language: String?, provider: DictionaryProviding) {
        self.text = text
        self.language = language
        self.provider = provider
        self.tokens = WordTokenizer.tokens(in: text)
    }

    var hasWords: Bool { !tokens.isEmpty }
    var index: Int { min(max(Int(cursor.rounded()), 0), max(tokens.count - 1, 0)) }
    var currentWord: String { tokens.isEmpty ? "" : tokens[index].text }
    var context: WordContext? { WordContext.make(text: text, tokens: tokens, index: index) }
    var maxCursor: Double { Double(max(tokens.count - 1, 1)) }

    func step(_ delta: Int) {
        guard hasWords else { return }
        cursor = Double(min(max(index + delta, 0), tokens.count - 1))
    }

    /// Looks up the current word. A newer call supersedes an older one still in flight.
    func lookup() async {
        guard hasWords else { return }
        let word = currentWord
        state = .loading
        do {
            let entry = try await provider.lookup(word, language: language)
            guard word == currentWord else { return }
            state = .loaded(entry)
        } catch let e as DictionaryError {
            state = .failed(e)
        } catch {
            if Task.isCancelled { return }
            state = .failed(.offline)
        }
    }
}
