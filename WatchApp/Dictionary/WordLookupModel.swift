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

    /// - Parameter initialCharacterOffset: character offset in `text` of the word to start on (the tapped
    ///   word, or the reading line); nil starts on the first word.
    init(text: String, language: String?, provider: DictionaryProviding, haptics: HapticPlaying = WatchHaptics(),
         initialCharacterOffset: Int? = nil) {
        self.text = text
        self.language = language
        self.provider = provider
        self.haptics = haptics
        let tokens = WordTokenizer.tokens(in: text, language: language)
        self.tokens = tokens
        if let offset = initialCharacterOffset {
            cursor = Double(TapPosition.tokenIndex(forCharacterOffset: offset, in: text, tokens: tokens))
        }
    }

    var hasWords: Bool { !tokens.isEmpty }
    var index: Int { Self.wordIndex(forCrownValue: cursor, wordCount: tokens.count) }
    var currentWord: String { tokens.isEmpty ? "" : tokens[index].text }
    var context: WordContext? { WordContext.make(text: text, tokens: tokens, index: index) }
    var maxCursor: Double { Double(max(tokens.count - 1, 1)) }

    /// The word a crown value selects: the nearest detent, clamped to the words (0 when there are none).
    nonisolated static func wordIndex(forCrownValue value: Double, wordCount: Int) -> Int {
        guard wordCount > 0, value.isFinite else { return 0 }
        return min(max(Int(value.rounded()), 0), wordCount - 1)
    }

    /// The crown value that sits exactly on the word `value` selects: a whole detent within the words.
    /// Used to re-sync the crown when it takes the cursor back, so it never resumes from a stale,
    /// fractional or out-of-range value.
    nonisolated static func crownValue(snapping value: Double, wordCount: Int) -> Double {
        Double(wordIndex(forCrownValue: value, wordCount: wordCount))
    }

    /// Snaps `cursor` onto the selected word's detent (no-op when it already is there).
    func resyncCursor() {
        let snapped = Self.crownValue(snapping: cursor, wordCount: tokens.count)
        if cursor != snapped { cursor = snapped }
    }

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
