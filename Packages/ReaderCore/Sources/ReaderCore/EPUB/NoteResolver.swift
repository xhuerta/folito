import Foundation

/// One spine document as extracted by `BlockExtractor.extractLocatingAllIDs`, for `NoteResolver`.
struct ExtractedDocument {
    /// Archive path of the document.
    var path: String
    var blocks: [RawBlock]
    /// Every id of the document (see `AnchorTarget`).
    var anchors: [String: AnchorTarget]
}

/// Note references found in a book, by document (same order as the input) and block index.
struct NoteResolution: Equatable {
    var notes: [[Int: [NoteReference]]]
    /// Blocks of `<aside>` notes that are shown as popups and can leave the text flow, by document.
    var hidden: [Set<Int>]
}

/// Decides which internal links are note references and copies each note's text next to its reference (#66).
///
/// Rules, in order:
/// - Back links (`epub:type="backlink"`), links without a `#fragment`, links to a place in the same paragraph
///   and links whose target is not in a spine document are never notes.
/// - EPUB 3: a link marked `epub:type="noteref"` (or `role="doc-noteref"`), or any link whose target is an
///   element marked as a note (`footnote`, `endnote`, `rearnote`, `note`; `aside`, `li`, `section`, `div`,
///   `p`, ...), is a note reference. The note's text is every block of that element. A noteref whose target is
///   not marked as a note takes the target paragraph, unless it is a heading.
/// - EPUB 2 heuristic: a link whose text is a short marker ("1", "[12]", "*", "†", "iv", "a") that is a
///   superscript, bracketed or has a note-like class (`noteref`, `fnanchor`, ...), that does not start its
///   paragraph (in a note, the marker that starts the paragraph is the link back to the text), and whose target
///   is the start of a short paragraph or list item (at most `maxHeuristicTargetLength` characters, not a
///   heading) that confirms it is a note: it begins with the same marker, links back to the reference's
///   paragraph, or lies in a footnotes / endnotes section.
/// - Anything else (chapter links, cross references, TOC entries) stays an ordinary link, as before.
enum NoteResolver {
    /// Notes longer than this are cut (with an ellipsis) so a stray huge target cannot bloat the book.
    static let maxNoteLength = 4000
    /// Longest target paragraph the EPUB 2 heuristic accepts.
    static let maxHeuristicTargetLength = 1500

    static func resolve(_ documents: [ExtractedDocument]) -> NoteResolution {
        var docIndexByPath: [String: Int] = [:]
        for (i, doc) in documents.enumerated() where docIndexByPath[doc.path] == nil { docIndexByPath[doc.path] = i }
        // Blocks of each note region, by document and region serial (blocks of a region are contiguous).
        let regionBlocks: [[Int: [Int]]] = documents.map { doc in
            var out: [Int: [Int]] = [:]
            for (bi, block) in doc.blocks.enumerated() {
                if let serial = block.note?.serial { out[serial, default: []].append(bi) }
            }
            return out
        }

        var notes = Array(repeating: [Int: [NoteReference]](), count: documents.count)
        var hidden = Array(repeating: Set<Int>(), count: documents.count)

        func target(of href: String, from path: String) -> (doc: Int, fragment: String)? {
            guard let hash = href.firstIndex(of: "#") else { return nil }
            let filePart = String(href[..<hash])
            let fragment = EPUBParser.percentDecode(String(href[href.index(after: hash)...]))
            guard !fragment.isEmpty else { return nil }
            let targetPath: String
            if filePart.isEmpty {
                targetPath = path
            } else {
                guard let resolved = EPUBParser.resolve(filePart, relativeTo: path) else { return nil }
                targetPath = resolved
            }
            guard let doc = docIndexByPath[targetPath] else { return nil }
            return (doc, fragment)
        }

        for (di, doc) in documents.enumerated() {
            for (bi, block) in doc.blocks.enumerated() where !block.links.isEmpty {
                var found: [NoteReference] = []
                for link in block.links where !link.isBacklink {
                    guard let linkTarget = target(of: link.href, from: doc.path) else { continue }
                    let ti = linkTarget.doc
                    let fragment = linkTarget.fragment
                    guard let anchor = documents[ti].anchors[fragment],
                          documents[ti].blocks.indices.contains(anchor.blockIndex),
                          !(ti == di && anchor.blockIndex == bi) else { continue }
                    let targetDoc = documents[ti]
                    let targetBlock = targetDoc.blocks[anchor.blockIndex]
                    let marker = markerLabel(link.text)

                    // EPUB 3: the target is (the start of) an element marked as a note.
                    if let region = targetBlock.note,
                       let members = regionBlocks[ti][region.serial],
                       region.id == fragment || (anchor.characterOffset == 0 && members.first == anchor.blockIndex),
                       !(ti == di && block.note?.serial == region.serial) {
                        let text = noteText(members.map { targetDoc.blocks[$0].text }, label: marker?.label)
                        guard !text.isEmpty else { continue }
                        found.append(reference(link, label: marker?.label, kind: region.kind, text: text))
                        if region.isAside { hidden[ti].formUnion(members) }
                        continue
                    }
                    // EPUB 3: an explicit noteref to an element that is not marked as a note.
                    if link.isNoteRef {
                        guard !targetBlock.style.isHeading else { continue }
                        let start = min(anchor.characterOffset, targetBlock.text.count)
                        let text = noteText([String(targetBlock.text.dropFirst(start))], label: marker?.label)
                        guard !text.isEmpty else { continue }
                        let kind = targetBlock.notesSection ?? (ti == di ? .footnote : .endnote)
                        found.append(reference(link, label: marker?.label, kind: kind, text: text))
                        continue
                    }
                    // EPUB 2 heuristic.
                    guard let marker, link.looksLikeMarker || marker.bracketed, link.characterOffset > 0,
                          !link.isInsideNote, anchor.characterOffset == 0,
                          targetBlock.style == .paragraph || targetBlock.style == .listItem || targetBlock.style == .quote,
                          targetBlock.text.count <= maxHeuristicTargetLength else { continue }
                    let startsWithMarker = strippedMarker(targetBlock.text, label: marker.label) != nil
                    let linksBack = targetBlock.links.contains { back in
                        guard let backTarget = target(of: back.href, from: targetDoc.path), backTarget.doc == di else {
                            return false
                        }
                        return documents[di].anchors[backTarget.fragment]?.blockIndex == bi
                    }
                    guard startsWithMarker || linksBack || targetBlock.notesSection != nil else { continue }
                    let text = noteText([targetBlock.text], label: marker.label)
                    guard !text.isEmpty else { continue }
                    let kind = targetBlock.notesSection ?? (ti == di ? .footnote : .endnote)
                    found.append(reference(link, label: marker.label, kind: kind, text: text))
                }
                if !found.isEmpty { notes[di][bi] = found }
            }
        }
        return NoteResolution(notes: notes, hidden: hidden)
    }

    private static func reference(_ link: RawLink, label: String?, kind: NoteKind, text: String) -> NoteReference {
        NoteReference(location: link.utf16Location, length: link.utf16Length,
                      label: label ?? (link.text.count <= 8 ? link.text : ""), kind: kind, text: text)
    }

    // MARK: - Markers

    private static let brackets: [(Character, Character)] = [("[", "]"), ("(", ")"), ("{", "}"), ("<", ">")]
    private static let symbolMarkers: Set<Character> = ["*", "\u{2020}", "\u{2021}", "\u{00A7}", "\u{00B6}", "\u{2016}", "#"]
    private static let superscriptDigits: Set<Character> = ["\u{2070}", "\u{00B9}", "\u{00B2}", "\u{00B3}", "\u{2074}",
                                                            "\u{2075}", "\u{2076}", "\u{2077}", "\u{2078}", "\u{2079}"]
    private static let romanLetters: Set<Character> = ["i", "v", "x", "l", "c", "I", "V", "X", "L", "C"]

    /// The label of a note marker ("12" for "[12]") and whether it was bracketed; nil when the text does not
    /// look like a marker (a word, a long number, a chapter title).
    static func markerLabel(_ text: String) -> (label: String, bracketed: Bool)? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var bracketed = false
        if t.count >= 3, let first = t.first, let last = t.last,
           brackets.contains(where: { $0.0 == first && $0.1 == last }) {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            bracketed = true
        }
        guard !t.isEmpty, t.count <= 4 else { return nil }
        let isDigits = t.count <= 3 && t.allSatisfy { $0.isASCII && $0.isNumber }
        let isSuperscriptDigits = t.count <= 3 && t.allSatisfy { superscriptDigits.contains($0) }
        let isSymbols = t.count <= 3 && t.allSatisfy { symbolMarkers.contains($0) }
        let isLetter = t.count == 1 && t.first?.isLetter == true
        let isRoman = t.allSatisfy { romanLetters.contains($0) }
        guard isDigits || isSuperscriptDigits || isSymbols || isLetter || isRoman else { return nil }
        return (t, bracketed)
    }

    /// `text` without a leading "[1]", "(1)", "1." or "1)" marker for `label`, or nil when it does not start
    /// with one.
    static func strippedMarker(_ text: String, label: String) -> String? {
        let forms = ["[\(label)]", "(\(label))", "{\(label)}", "\(label).", "\(label))", "\(label):"]
        for form in forms where text.hasPrefix(form) {
            let rest = text.dropFirst(form.count)
            // "1." must be followed by a space, so "1.5 metres" is not taken for a marker.
            guard rest.isEmpty || rest.first?.isWhitespace == true else { continue }
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A bare label followed by a space (Gutenberg's "1 Note text" after an anchor) only for symbols.
        if label.allSatisfy({ symbolMarkers.contains($0) }), text.hasPrefix(label + " ") {
            return text.dropFirst(label.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Note text

    /// Characters of a link back to the text at the end of a note paragraph.
    private static let backlinkGlyphs: Set<Character> = ["\u{21A9}", "\u{21A9}\u{FE0E}", "\u{21A9}\u{FE0F}", "\u{2191}",
                                                         "\u{2934}", "\u{2B06}", "^"]

    /// The note's paragraphs joined by "\n", without a leading marker for `label`, trailing back-link glyphs
    /// or more than `maxNoteLength` characters.
    static func noteText(_ paragraphs: [String], label: String?) -> String {
        var parts: [String] = []
        for (i, paragraph) in paragraphs.enumerated() {
            var p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if i == 0, let label, let rest = strippedMarker(p, label: label) { p = rest }
            while let last = p.last, backlinkGlyphs.contains(last) || last.isWhitespace { p.removeLast() }
            if !p.isEmpty { parts.append(p) }
        }
        let text = parts.joined(separator: "\n")
        guard text.count > maxNoteLength else { return text }
        return String(text.prefix(maxNoteLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }
}

