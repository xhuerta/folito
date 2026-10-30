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
    private let haptics: HapticPlaying

    /// Raw crown value; the selected word is `index`.
    @Published var cursor: Double = 0
    @Published private(set) var state: State = .idle

    init(text: String, language: String?, provider: DictionaryProviding, haptics: HapticPlaying = WatchHaptics()) {
        self.text = text
        self.language = language
        self.provider = provider
        self.haptics = haptics
        self.tokens = WordTokenizer.tokens(in: text)
    }

    var hasWords: Bool { !tokens.isEmpty }
    var index: Int { min(max(Int(cursor.rounded()), 0), max(tokens.count - 1, 0)) }
    var currentWord: String { tokens.isEmpty ? "" : tokens[index].text }
    var context: WordContext? { WordContext.make(text: text, tokens: tokens, index: index) }
    var maxCursor: Double { Double(max(tokens.count - 1, 1)) }

    var canStepBack: Bool { hasWords && index > 0 }
    var canStepForward: Bool { hasWords && index < tokens.count - 1 }

    /// Moves the cursor by `delta` words (buttons and VoiceOver). Plays a click when it actually moved.
    /// Returns whether it moved.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        guard hasWords else { return false }
        let target = min(max(index + delta, 0), tokens.count - 1)
        guard target != index else { return false }
        cursor = Double(target)
        haptics.play(.cursorMoved)
        return true
    }

    /// VoiceOver adjustable action (swipe up / down, or the crown with VoiceOver): next / previous word.
    func adjust(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: step(1)
        case .decrement: step(-1)
        @unknown default: break
        }
    }

    /// "Word 3 of 12".
    var positionText: String {
        String(localized: "Word \(index + 1) of \(tokens.count)",
               comment: "Position of the selected word in the paragraph")
    }

    /// What VoiceOver reads for the cursor: the word, then its position.
    var accessibilityValue: String {
        String(localized: "\(currentWord), word \(index + 1) of \(tokens.count)",
               comment: "VoiceOver value of the word cursor: the selected word and its position")
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
            haptics.play(.lookupSucceeded)
        } catch let e as DictionaryError {
            guard word == currentWord else { return }
            state = .failed(e)
            haptics.play(.lookupFailed)
        } catch {
            if Task.isCancelled { return }
            state = .failed(.unreadable)
            haptics.play(.lookupFailed)
        }
    }
}
