import Foundation

/// One definition of a word, with optional usage examples.
public struct DictionarySense: Codable, Equatable, Sendable {
    public var definition: String
    public var examples: [String]

    public init(definition: String, examples: [String] = []) {
        self.definition = definition
        self.examples = examples
    }
}

/// Senses grouped under a part of speech ("noun", "verb", ...).
public struct DictionaryMeaning: Codable, Equatable, Sendable {
    public var partOfSpeech: String
    public var senses: [DictionarySense]

    public init(partOfSpeech: String, senses: [DictionarySense]) {
        self.partOfSpeech = partOfSpeech
        self.senses = senses
    }
}

public struct DictionaryEntry: Codable, Equatable, Sendable {
    /// The form that matched (may differ from the tapped word after a lemma retry).
    public var word: String
    /// Primary language subtag the entry belongs to ("en", "es", ...).
    public var language: String
    public var pronunciation: String?
    public var meanings: [DictionaryMeaning]
    /// Human-readable provider name, for attribution.
    public var source: String

    public init(word: String, language: String, pronunciation: String? = nil,
                meanings: [DictionaryMeaning], source: String) {
        self.word = word
        self.language = language
        self.pronunciation = pronunciation
        self.meanings = meanings
        self.source = source
    }

    public var isEmpty: Bool { meanings.allSatisfy { $0.senses.isEmpty } }
}

public enum DictionaryError: Error, Equatable, Sendable {
    case offline
    case notFound
    case rateLimited
    case server(status: Int)
    case invalidResponse

    /// Short text for the watch UI.
    public var userMessage: String {
        switch self {
        case .offline: return "You're offline. Only words already looked up are available without a connection."
        case .notFound: return "No definition found."
        case .rateLimited: return "The dictionary is busy. Try again in a moment."
        case .server(let status): return "Dictionary error (HTTP \(status))."
        case .invalidResponse: return "Unexpected dictionary response."
        }
    }
}

/// Looks words up. Implementations: `DictionaryService` (online + cache) and `MockDictionaryProvider`.
public protocol DictionaryProviding: Sendable {
    /// `language` is a BCP-47 tag from the book metadata (nil = English).
    func lookup(_ word: String, language: String?) async throws -> DictionaryEntry
}

/// Preview/test double.
public struct MockDictionaryProvider: DictionaryProviding {
    public var entries: [String: DictionaryEntry]
    public var error: DictionaryError?
    public var delayNanoseconds: UInt64

    public init(entries: [String: DictionaryEntry] = [:], error: DictionaryError? = nil, delayNanoseconds: UInt64 = 0) {
        self.entries = entries
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    public func lookup(_ word: String, language: String?) async throws -> DictionaryEntry {
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        if let error { throw error }
        let key = WordNormalizer.clean(word).lowercased()
        if let entry = entries[key] { return entry }
        throw DictionaryError.notFound
    }

    public static var sample: MockDictionaryProvider {
        let run = DictionaryEntry(
            word: "run", language: "en", pronunciation: "/ɹʌn/",
            meanings: [
                DictionaryMeaning(partOfSpeech: "verb", senses: [
                    DictionarySense(definition: "To move swiftly on foot.", examples: ["I run every morning."]),
                    DictionarySense(definition: "To operate or function."),
                ]),
                DictionaryMeaning(partOfSpeech: "noun", senses: [
                    DictionarySense(definition: "An act of running."),
                ]),
            ],
            source: "Wiktionary")
        return MockDictionaryProvider(entries: ["run": run, "running": run])
    }
}
