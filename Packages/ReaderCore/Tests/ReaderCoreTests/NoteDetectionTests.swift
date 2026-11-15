import XCTest
@testable import ReaderCore

/// Footnotes and endnotes shown in place (#66): which links become note references, and the note text kept
/// with them.
final class NoteDetectionTests: XCTestCase {
    private func xhtml(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>T</title></head>
        <body>\(body)</body></html>
        """.utf8)
    }

    /// A book whose spine is `documents` (`c1.xhtml`, `c2.xhtml`, ... in order).
    private func book(_ documents: [String]) throws -> ProcessedBook {
        let ids = documents.indices.map { "c\($0 + 1)" }
        var entries: [(String, Data)] = [("META-INF/container.xml", EPUBTestSupport.container),
                                         ("content.opf", EPUBTestSupport.opf(spine: ids))]
        for (id, body) in zip(ids, documents) { entries.append(("\(id).xhtml", xhtml(body))) }
        return try EPUBTestSupport.parser().process(epubAt: try EPUBTestSupport.makeZip(entries))
    }

    private func utf16Offset(of marker: String, in text: String) -> Int {
        (text as NSString).range(of: marker).location
    }

    // MARK: - EPUB 3

    func testNoterefToAsideFootnoteKeepsTextAndHidesAside() throws {
        let b = try book(["""
        <p>Text with a note<a epub:type="noteref" href="#fn1">1</a> here.</p>
        <aside epub:type="footnote" id="fn1"><p>The note text.</p><p>Second paragraph.</p></aside>
        <p>After.</p>
        """])
        let blocks = b.chapters[0].blocks
        XCTAssertEqual(blocks.map(\.text), ["Text with a note1 here.", "After."], "the referenced aside leaves the flow")
        let note = try XCTUnwrap(blocks[0].notes?.first)
        XCTAssertEqual(blocks[0].notes?.count, 1)
        XCTAssertEqual(note.label, "1")
        XCTAssertEqual(note.kind, .footnote)
        XCTAssertEqual(note.text, "The note text.\nSecond paragraph.")
        XCTAssertEqual(note.location, utf16Offset(of: "1", in: blocks[0].text))
        XCTAssertEqual(note.length, 1)
        XCTAssertNil(blocks[1].notes)
        XCTAssertEqual(blocks[1].globalOffset, blocks[0].text.count, "offsets skip the hidden aside")
        XCTAssertEqual(b.totalCharacters, blocks[0].text.count + blocks[1].text.count)
        XCTAssertEqual(b.formatVersion, 1)
    }

    func testUnreferencedAsideStaysInTheText() throws {
        let b = try book(["""
        <p>Plain paragraph.</p>
        <aside epub:type="footnote" id="fn9"><p>Orphan note.</p></aside>
        """])
        XCTAssertEqual(b.chapters[0].blocks.map(\.text), ["Plain paragraph.", "Orphan note."])
    }

    func testEndnotesInAnotherFile() throws {
        let b = try book([
            """
            <p>See this<a id="r1" epub:type="noteref" href="c2.xhtml#n1">1</a> and that<a id="r2" role="doc-noteref" href="c2.xhtml#n2">2</a>.</p>
            """,
            """
            <section epub:type="endnotes"><h2>Notes</h2><ol>
            <li id="n1" epub:type="endnote"><p>First endnote. <a href="c1.xhtml#r1" epub:type="backlink">\u{21A9}</a></p></li>
            <li id="n2" epub:type="rearnote"><p>Second endnote.</p></li>
            </ol></section>
            """,
        ])
        let notes = try XCTUnwrap(b.chapters[0].blocks[0].notes)
        XCTAssertEqual(notes.map(\.label), ["1", "2"])
        XCTAssertEqual(notes.map(\.kind), [.endnote, .endnote])
        XCTAssertEqual(notes.map(\.text), ["First endnote.", "Second endnote."], "the back link glyph is dropped")
        // Endnote lists are not asides: the notes chapter stays readable as it was.
        XCTAssertEqual(b.chapters[1].blocks.map(\.text), ["Notes", "First endnote. \u{21A9}", "Second endnote."])
        XCTAssertTrue(b.chapters[1].blocks.allSatisfy { $0.notes == nil }, "back links are not note references")
    }

    // MARK: - EPUB 2 heuristic

    func testSuperscriptLinkToNoteParagraph() throws {
        let b = try book(["""
        <p>A bold claim<sup><a href="#fn1" id="r1">1</a></sup> and more text.</p>
        <hr/>
        <p class="footnote"><a id="fn1" href="#r1">1.</a> A Gutenberg note.</p>
        """])
        let blocks = b.chapters[0].blocks
        XCTAssertEqual(blocks.count, 2, "EPUB 2 notes are not hidden")
        let note = try XCTUnwrap(blocks[0].notes?.first)
        XCTAssertEqual(note.label, "1")
        XCTAssertEqual(note.kind, .footnote)
        XCTAssertEqual(note.text, "A Gutenberg note.", "the leading marker is stripped")
        XCTAssertNil(blocks[1].notes, "the marker starting the note links back; it is not a reference")
    }

    func testBracketedGutenbergMarkerToEndnoteFile() throws {
        let b = try book([
            """
            <p>The voyage began<a id="FNanchor_2" href="c2.xhtml#Footnote_2" class="fnanchor">[2]</a> in spring.</p>
            """,
            """
            <div class="footnote"><p><a id="Footnote_2"></a><a href="c1.xhtml#FNanchor_2"><span class="label">[2]</span></a> In the year 1802.</p></div>
            """,
        ])
        let note = try XCTUnwrap(b.chapters[0].blocks[0].notes?.first)
        XCTAssertEqual(note.label, "2")
        XCTAssertEqual(note.kind, .endnote, "a note in another document is an endnote")
        XCTAssertEqual(note.text, "In the year 1802.")
        XCTAssertEqual(note.location, utf16Offset(of: "[2]", in: b.chapters[0].blocks[0].text))
        XCTAssertEqual(note.length, 3)
    }

    func testOrdinaryInternalLinksAreUntouched() throws {
        let documents = [
            """
            <p>See <a href="#ch2">the next part</a> and section <a href="c2.xhtml#sec">2</a>.</p>
            <p>A superscript<sup><a href="#body">3</a></sup> to a body paragraph.</p>
            <p id="ch2">Next part.</p>
            <p id="body">This long body paragraph does not start with a marker and is not in a notes section.</p>
            """,
            """
            <h2 id="sec">Section 2</h2><p>Text.</p>
            <ul><li><a href="c1.xhtml#ch2">1</a></li></ul>
            """,
        ]
        let b = try book(documents)
        XCTAssertTrue(b.chapters.allSatisfy { $0.blocks.allSatisfy { $0.notes == nil } })
        XCTAssertEqual(b.chapters[0].blocks.count, 4)
        XCTAssertEqual(b.chapters[0].blocks[0].text, "See the next part and section 2.")
    }

    func testLinkAtParagraphStartAndHeadingTargetsAreNotNotes() throws {
        let b = try book(["""
        <p><sup><a href="#n">1</a></sup> starts the paragraph.</p>
        <p>Text<sup><a href="#h">2</a></sup> here.</p>
        <h3 id="h">2. Heading</h3>
        <p id="n">1. Looks like a note.</p>
        """])
        XCTAssertTrue(b.chapters[0].blocks.allSatisfy { $0.notes == nil })
    }

    // MARK: - Helpers and model

    func testMarkerLabels() {
        XCTAssertEqual(NoteResolver.markerLabel("12")?.label, "12")
        XCTAssertEqual(NoteResolver.markerLabel("[12]")?.bracketed, true)
        XCTAssertEqual(NoteResolver.markerLabel("(iv)")?.label, "iv")
        XCTAssertEqual(NoteResolver.markerLabel("*")?.label, "*")
        XCTAssertEqual(NoteResolver.markerLabel("\u{2020}")?.label, "\u{2020}")
        XCTAssertEqual(NoteResolver.markerLabel("\u{00B9}")?.label, "\u{00B9}")
        XCTAssertNil(NoteResolver.markerLabel("1234"))
        XCTAssertNil(NoteResolver.markerLabel("Chapter 2"))
        XCTAssertNil(NoteResolver.markerLabel("word"))
        XCTAssertEqual(NoteResolver.strippedMarker("1. Text", label: "1"), "Text")
        XCTAssertEqual(NoteResolver.strippedMarker("[1] Text", label: "1"), "Text")
        XCTAssertNil(NoteResolver.strippedMarker("1.5 metres", label: "1"))
        XCTAssertNil(NoteResolver.strippedMarker("10. Text", label: "1"))
    }

    func testNoteTextIsCapped() {
        let long = String(repeating: "a", count: NoteResolver.maxNoteLength + 50)
        let text = NoteResolver.noteText([long], label: nil)
        XCTAssertEqual(text.count, NoteResolver.maxNoteLength + 1)
        XCTAssertTrue(text.hasSuffix("\u{2026}"))
    }

    func testNoteReferenceNearTap() {
        let text = "Caf\u{00E9} \u{1F600} claim1 and more"
        let location = utf16Offset(of: "1", in: text)
        let note = NoteReference(location: location, length: 1, label: "1", kind: .footnote, text: "N")
        let block = Block(text: text, xpointer: "", globalOffset: 0, notes: [note])
        let marker = 12  // character offset of "1" (the emoji is one character but two UTF-16 units)
        XCTAssertEqual(note.characterRange(in: text), marker..<(marker + 1))
        XCTAssertEqual(block.noteReference(nearCharacterOffset: marker), note)
        XCTAssertEqual(block.noteReference(nearCharacterOffset: marker - 3), note)
        XCTAssertEqual(block.noteReference(nearCharacterOffset: marker + 3), note)
        XCTAssertNil(block.noteReference(nearCharacterOffset: 0))
        XCTAssertNil(Block(text: text, xpointer: "", globalOffset: 0).noteReference(nearCharacterOffset: marker))
    }

    func testBlocksWithoutNotesDecodeAndEncodeWithoutTheKey() throws {
        let old = Data(#"{"text":"Hi","style":"paragraph","spans":[],"xpointer":"x","globalOffset":0}"#.utf8)
        let block = try JSONDecoder().decode(Block.self, from: old)
        XCTAssertNil(block.notes)
        let encoded = String(decoding: try JSONEncoder().encode(block), as: UTF8.self)
        XCTAssertFalse(encoded.contains("notes"), "books without notes keep their size and shape")
        let withNote = Block(text: "a1", xpointer: "x", globalOffset: 0,
                             notes: [NoteReference(location: 1, length: 1, label: "1", kind: .endnote, text: "N")])
        XCTAssertEqual(try JSONDecoder().decode(Block.self, from: JSONEncoder().encode(withNote)), withNote)
    }
}
