import Foundation

/// Limits keeping a result readable (and small) on a watch screen and in the on-disk cache.
public enum DictionaryLimits {
    public static let meanings = 5
    public static let sensesPerMeaning = 6
    public static let examplesPerSense = 1
    public static let maxDefinitionLength = 400
}

/// Parser for the Wiktionary REST `page/definition/{word}` response (English edition).
///
/// Real response shape (verified, see Tests/Fixtures/Dictionary):
/// `{ "<entry-language-code>": [ { "partOfSpeech", "language", "definitions": [ { "definition": "<html>",
///    "parsedExamples": [ { "example": "<html>", "translation"?: "<html>" } ], "examples": [..] } ] } ] }`
/// A definition with sub-senses embeds them as a nested `<ol>` AND repeats each sub-sense as its own
/// following element, so the nested list is dropped from the parent to avoid duplicates.
public enum WiktionaryParser {
    public static let sourceName = "Wiktionary"

    /// `language` is the primary language subtag of the *word* (the JSON key). Returns nil when the page
    /// has no section for that language.
    public static func parse(_ data: Data, word: String, language: String) -> DictionaryEntry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var sections: [[String: Any]] = []
        for key in languageKeys(for: language) {
            if let list = root[key] as? [[String: Any]] { sections = list; break }
        }
        guard !sections.isEmpty else { return nil }

        var meanings: [DictionaryMeaning] = []
        for section in sections {
            guard let pos = section["partOfSpeech"] as? String,
                  let defs = section["definitions"] as? [[String: Any]] else { continue }
            var senses: [DictionarySense] = []
            for def in defs {
                guard let html = def["definition"] as? String else { continue }
                var text = HTMLText.plain(html, dropNestedLists: true)
                guard !text.isEmpty else { continue }
                if text.count > DictionaryLimits.maxDefinitionLength {
                    text = String(text.prefix(DictionaryLimits.maxDefinitionLength - 1)) + "\u{2026}"
                }
                if senses.contains(where: { $0.definition == text }) { continue }
                senses.append(DictionarySense(definition: text, examples: examples(in: def)))
                if senses.count >= DictionaryLimits.sensesPerMeaning { break }
            }
            guard !senses.isEmpty else { continue }
            // The same part of speech can appear several times (several etymologies): merge.
            let label = pos.lowercased()
            if let i = meanings.firstIndex(where: { $0.partOfSpeech == label }) {
                let room = DictionaryLimits.sensesPerMeaning - meanings[i].senses.count
                if room > 0 { meanings[i].senses += senses.prefix(room) }
            } else if meanings.count < DictionaryLimits.meanings {
                meanings.append(DictionaryMeaning(partOfSpeech: label, senses: senses))
            }
        }
        guard !meanings.isEmpty else { return nil }
        return DictionaryEntry(word: word, language: language, meanings: meanings, source: sourceName)
    }

    /// Wiktionary keys sections by 2-letter code when one exists.
    static func languageKeys(for language: String) -> [String] { [language] }

    private static func examples(in def: [String: Any]) -> [String] {
        var out: [String] = []
        if let parsed = def["parsedExamples"] as? [[String: Any]] {
            for p in parsed {
                if let html = p["example"] as? String {
                    let t = HTMLText.plain(html)
                    if !t.isEmpty { out.append(t) }
                }
                if out.count >= DictionaryLimits.examplesPerSense { break }
            }
        } else if let raw = def["examples"] as? [String] {
            for html in raw {
                let t = HTMLText.plain(html)
                if !t.isEmpty { out.append(t) }
                if out.count >= DictionaryLimits.examplesPerSense { break }
            }
        }
        return out
    }
}

/// Parser for api.dictionaryapi.dev `/api/v2/entries/{lang}/{word}`.
/// Shape: `[ { "word", "phonetic"?, "phonetics": [ { "text"? } ], "meanings": [ { "partOfSpeech",
/// "definitions": [ { "definition", "example"? } ] } ] } ]`; a miss is HTTP 404 with
/// `{ "title": "No Definitions Found", ... }`.
public enum DictionaryAPIParser {
    public static let sourceName = "dictionaryapi.dev"

    public static func parse(_ data: Data, language: String) -> DictionaryEntry? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else { return nil }
        let word = (first["word"] as? String) ?? ""
        var pronunciation = first["phonetic"] as? String
        if pronunciation?.isEmpty != false {
            pronunciation = (first["phonetics"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.first { !$0.isEmpty }
        }
        var meanings: [DictionaryMeaning] = []
        for entry in array {
            for m in (entry["meanings"] as? [[String: Any]]) ?? [] {
                guard let pos = m["partOfSpeech"] as? String else { continue }
                var senses: [DictionarySense] = []
                for d in (m["definitions"] as? [[String: Any]]) ?? [] {
                    guard let text = (d["definition"] as? String).map({ HTMLText.plain($0) }), !text.isEmpty else { continue }
                    let ex = (d["example"] as? String).map { HTMLText.plain($0) }.flatMap { $0.isEmpty ? nil : [$0] } ?? []
                    senses.append(DictionarySense(definition: text, examples: ex))
                    if senses.count >= DictionaryLimits.sensesPerMeaning { break }
                }
                if !senses.isEmpty, meanings.count < DictionaryLimits.meanings {
                    meanings.append(DictionaryMeaning(partOfSpeech: pos.lowercased(), senses: senses))
                }
            }
        }
        guard !meanings.isEmpty, !word.isEmpty else { return nil }
        return DictionaryEntry(word: word, language: language, pronunciation: pronunciation,
                               meanings: meanings, source: sourceName)
    }
}
