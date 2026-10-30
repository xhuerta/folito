import Foundation

/// Turns one StarDict definition into a `DictionaryEntry`.
///
/// HTML definitions (`sametypesequence=h`) as built by reader.dict from Wiktionary look like
/// `"/pronunciation/\n<p><b>Noun</b> <i>f.</i></p><ol><li>sense</li><ol><li>sub-sense</li></ol>...</ol>"`:
/// an optional first line with the pronunciation, then one `<p>` heading per part of speech (or section
/// such as "Synonyms") followed by an ordered list of senses. A nested list right after (or inside) an
/// item holds that item's sub-senses. Inline markup inside headings and items is flattened with
/// `HTMLText.plain`. Plain-text definitions (`m`, `t`, ...) become one sense per line.
public enum StarDictDefinition {
    public static func parse(_ raw: String, word: String, language: String, source: String,
                             type: Character = "h") -> DictionaryEntry? {
        let parsed: (String?, [DictionaryMeaning])
        if type == "h" || type == "g" || type == "x" {
            parsed = parseHTML(raw)
        } else {
            parsed = (nil, parsePlain(raw))
        }
        let meanings = parsed.1.filter { !$0.senses.isEmpty }
        guard !meanings.isEmpty else { return nil }
        return DictionaryEntry(word: word, language: language, pronunciation: parsed.0,
                               meanings: meanings, source: source)
    }

    static func clip(_ text: String) -> String {
        guard text.count > DictionaryLimits.maxDefinitionLength else { return text }
        return String(text.prefix(DictionaryLimits.maxDefinitionLength - 1)) + "\u{2026}"
    }

    private static func parsePlain(_ raw: String) -> [DictionaryMeaning] {
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(DictionaryLimits.sensesPerMeaning)
        return [DictionaryMeaning(partOfSpeech: "", senses: lines.map { DictionarySense(definition: clip($0)) })]
    }

    // MARK: HTML

    private struct Builder {
        var meanings: [DictionaryMeaning] = []
        var pos: String?
        var senses: [DictionarySense] = []

        mutating func startMeaning(_ heading: String) {
            finishMeaning()
            pos = heading
        }

        mutating func finishMeaning() {
            defer { senses = []; pos = nil }
            guard !senses.isEmpty else { return }
            let label = pos ?? ""
            // The same heading can come back (several etymologies): merge into the first one.
            if let i = meanings.firstIndex(where: { $0.partOfSpeech == label }) {
                let room = DictionaryLimits.sensesPerMeaning - meanings[i].senses.count
                if room > 0 { meanings[i].senses += senses.prefix(room) }
            } else if meanings.count < DictionaryLimits.meanings {
                meanings.append(DictionaryMeaning(partOfSpeech: label, senses: senses))
            }
        }

        mutating func addSense(_ html: String) {
            let text = clip(HTMLText.plain(html))
            guard !text.isEmpty, senses.count < DictionaryLimits.sensesPerMeaning,
                  !senses.contains(where: { $0.definition == text }) else { return }
            senses.append(DictionarySense(definition: text))
        }

        mutating func addSubsense(_ html: String) {
            let text = clip(HTMLText.plain(html))
            guard !text.isEmpty else { return }
            guard !senses.isEmpty else { addSense(html); return }
            if senses[senses.count - 1].subsenses.count < DictionaryLimits.subsensesPerSense {
                senses[senses.count - 1].subsenses.append(text)
            }
        }
    }

    /// An open `<li>`: its HTML so far, its list depth and whether it was already emitted (because a
    /// nested list started inside it, so that the parent comes before its sub-senses).
    private struct OpenItem {
        var html = ""
        var depth: Int
        var emitted = false
    }

    static func parseHTML(_ raw: String) -> (String?, [DictionaryMeaning]) {
        var html = Substring(raw)
        var pronunciation: String?
        if let first = html.first, first != "<" {
            let end = html.firstIndex(where: { $0 == "\n" || $0 == "<" }) ?? html.endIndex
            let line = HTMLText.plain(String(html[..<end]))
            if !line.isEmpty, line.count <= 120 { pronunciation = line }
            html = html[end...]
        }

        var b = Builder()
        var depth = 0
        var heading: String?
        var items: [OpenItem] = []
        var loose = ""

        func append(_ s: Substring) {
            if heading != nil { heading! += s } else if !items.isEmpty { items[items.count - 1].html += s } else { loose += s }
        }
        func emit(_ item: OpenItem) {
            if item.depth <= 1 { b.addSense(item.html) } else { b.addSubsense(item.html) }
        }

        var i = html.startIndex
        while i < html.endIndex {
            guard html[i] == "<", let close = html[i...].firstIndex(of: ">") else {
                let next = html[html.index(after: i)...].firstIndex(of: "<") ?? html.endIndex
                append(html[i..<next])
                i = next
                continue
            }
            let inner = html[html.index(after: i)..<close]
            let isClose = inner.first == "/"
            let name = String((isClose ? inner.dropFirst() : inner).prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
            let tag = html[i...close]
            i = html.index(after: close)
            switch (name, isClose) {
            case ("p", false) where depth == 0 && items.isEmpty:
                heading = ""
            case ("p", true) where heading != nil:
                b.startMeaning(HTMLText.plain(heading!))
                heading = nil
            case ("ol", false), ("ul", false):
                if let last = items.indices.last, !items[last].emitted {
                    emit(items[last])
                    items[last].emitted = true
                }
                depth += 1
            case ("ol", true), ("ul", true):
                // Items left open by sloppy markup end with their list.
                while let last = items.last, last.depth >= depth {
                    if !last.emitted { emit(last) }
                    items.removeLast()
                }
                depth = max(0, depth - 1)
            case ("li", false):
                // An unclosed sibling item ends where the next one starts.
                while let last = items.last, last.depth >= max(depth, 1) {
                    if !last.emitted { emit(last) }
                    items.removeLast()
                }
                items.append(OpenItem(depth: max(depth, 1)))
            case ("li", true):
                if let last = items.popLast(), !last.emitted { emit(last) }
            default:
                append(tag)
            }
        }
        while let last = items.popLast() {
            if !last.emitted { emit(last) }
        }
        if b.senses.isEmpty, b.meanings.isEmpty, b.pos == nil {
            b.addSense(loose)
        }
        b.finishMeaning()
        return (pronunciation, b.meanings)
    }
}
