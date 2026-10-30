import Foundation

/// One definition of a word, with optional usage examples and sub-senses (more specific meanings that the
/// source lists under this one).
public struct DictionarySense: Codable, Equatable, Sendable {
    public var definition: String
    public var examples: [String]
    public var subsenses: [String]

    public init(definition: String, examples: [String] = [], subsenses: [String] = []) {
        self.definition = definition
        self.examples = examples
        self.subsenses = subsenses
    }
}

/// Senses grouped under a part of speech ("noun", "verb", ...) or another section heading of the source
/// ("Synonyms", ...).
public struct DictionaryMeaning: Codable, Equatable, Sendable {
    public var partOfSpeech: String
    public var senses: [DictionarySense]

    public init(partOfSpeech: String, senses: [DictionarySense]) {
        self.partOfSpeech = partOfSpeech
        self.senses = senses
    }
}

public struct DictionaryEntry: Codable, Equatable, Sendable {
    /// The headword that matched (may differ from the tapped word: a lemma, or the base form of an
    /// inflected form).
    public var word: String
    /// Primary language subtag the entry belongs to ("en", "es", ...).
    public var language: String
    public var pronunciation: String?
    public var meanings: [DictionaryMeaning]
    /// Human-readable name of the dictionary, for attribution.
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

/// Limits keeping a result readable on a watch screen, and the converted dictionaries small.
public enum DictionaryLimits {
    public static let meanings = 6
    public static let sensesPerMeaning = 8
    public static let subsensesPerSense = 4
    public static let examplesPerSense = 1
    public static let maxDefinitionLength = 400
    /// Entries merged into one result when several headwords share a lookup key ("Polish" / "polish").
    public static let entriesPerLookup = 3
}

public enum DictionaryError: Error, Equatable, Sendable {
    /// No dictionary is installed on this device.
    case noDictionary
    /// The installed dictionaries have no entry for the word or any of its candidate forms.
    case notFound
    /// An installed dictionary file could not be read (damaged or from a newer app version).
    case unreadable
}

/// Looks words up. Implementations: `OfflineDictionaryService` (installed dictionaries) and
/// `MockDictionaryProvider`.
public protocol DictionaryProviding: Sendable {
    /// `language` is a BCP-47 tag from the book metadata (nil = unknown).
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
                    DictionarySense(definition: "To move swiftly on foot.", examples: ["I run every morning."],
                                    subsenses: ["To compete in a race."]),
                    DictionarySense(definition: "To operate or function."),
                ]),
                DictionaryMeaning(partOfSpeech: "noun", senses: [
                    DictionarySense(definition: "An act of running."),
                ]),
            ],
            source: "Wiktionary (reader.dict)")
        return MockDictionaryProvider(entries: ["run": run, "running": run])
    }
}
