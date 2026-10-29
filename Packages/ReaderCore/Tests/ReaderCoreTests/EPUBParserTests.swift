import XCTest
import ZIPFoundation
@testable import ReaderCore

struct FakeIdentity: DocumentIdentifying {
    func partialMD5(fileAt url: URL) throws -> String { "file-hash" }
    func partialMD5(of data: Data) -> String { "data-hash" }
    func metaHash(for metadata: BookMetadata) -> String { "meta:" + metadata.title }
}

struct FakeXPointers: XPointerGenerating {
    func xpointer(spineIndex: Int, path: [PathStep], textOffset: Int?) -> String {
        "\(spineIndex):" + path.map { "\($0.name)[\($0.index)]" }.joined(separator: "/") + "@\(textOffset.map(String.init) ?? "-")"
    }
}

enum EPUBTestSupport {
    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func fixture(_ name: String) -> URL { fixturesDir.appendingPathComponent(name + ".epub") }

    static func parser() -> EPUBParser { EPUBParser(identity: FakeIdentity(), xpointers: FakeXPointers()) }

    static func parse(_ name: String) throws -> ProcessedBook {
        try parser().process(epubAt: fixture(name))
    }

    /// Builds an EPUB (ZIP) in a temp directory from raw entries, preserving odd entry names.
    static func makeZip(_ entries: [(String, Data)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in entries {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        return url
    }

    static let container = Data("""
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """.utf8)

    static func opf(spine: [String] = ["c1"], manifestExtra: String = "") -> Data {
        let items = spine.map { "<item id=\"\($0)\" href=\"\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let refs = spine.map { "<itemref idref=\"\($0)\"/>" }.joined()
        return Data("""
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>T</dc:title></metadata><manifest>\(items)\(manifestExtra)</manifest><spine>\(refs)</spine></package>
        """.utf8)
    }
}

final class EPUBParserTests: XCTestCase {
    func testSimpleMetadataAndBlocks() throws {
        let book = try EPUBTestSupport.parse("simple")
        XCTAssertEqual(book.metadata.title, "Simple Book")
        XCTAssertEqual(book.metadata.authors, ["Jane Author", "John Coauthor"])
        XCTAssertEqual(book.metadata.language, "en")
        XCTAssertEqual(book.metadata.identifiers, [BookIdentifier(scheme: "UUID", value: "urn:uuid:1234"),
                                                   BookIdentifier(scheme: "ISBN", value: "9781234567890")])
        XCTAssertEqual(book.documentHash, "file-hash")
        XCTAssertEqual(book.metaHash, "meta:Simple Book")
        XCTAssertEqual(book.chapters.count, 1)
        let ch = book.chapters[0]
        XCTAssertEqual(ch.spineIndex, 1)
        XCTAssertEqual(ch.title, "Chapter One")
        XCTAssertEqual(ch.blocks.map(\.text), ["Chapter One", "Hello, world. Second line.", "Another paragraph."])
        XCTAssertEqual(ch.blocks.map(\.style), [.heading1, .paragraph, .paragraph])
        XCTAssertEqual(ch.blocks.map(\.xpointer), ["1:h1[1]@0", "1:p[1]@0", "1:p[2]@0"])
        XCTAssertEqual(ch.blocks.map(\.globalOffset), [0, 11, 37])
        XCTAssertEqual(book.totalCharacters, 55)
    }

    func testNestedBlocksNoDuplication() throws {
        let b = try EPUBTestSupport.parse("nested").chapters[0].blocks
        XCTAssertEqual(b.map(\.text), ["Inner one", "Inner two", "Tail text", "Deep span em text", "Quoted", "Item A", "Item B", "Sub"])
        XCTAssertEqual(b.map(\.xpointer), [
            "1:div[1]/div[1]/p[1]@0", "1:div[1]/div[1]/p[2]@0", "1:div[1]@0", "1:div[1]/div[2]@0",
            "1:blockquote[1]/p[1]@0", "1:ul[1]/li[1]@0", "1:ul[1]/li[2]@0", "1:h2[1]@0",
        ])
        XCTAssertEqual(b[4].style, .quote)
        XCTAssertEqual(b[5].style, .listItem)
        XCTAssertEqual(b[7].style, .heading2)
        // Offsets are cumulative and contiguous.
        var expected = 0
        for blk in b { XCTAssertEqual(blk.globalOffset, expected); expected += blk.text.count }
    }

    func testInlineSpans() throws {
        let b = try EPUBTestSupport.parse("inline").chapters[0].blocks
        XCTAssertEqual(b[0].text, "Plain bold and italic and both end.")
        XCTAssertEqual(b[0].spans, [
            StyleSpan(location: 6, length: 4, bold: true, italic: false),
            StyleSpan(location: 15, length: 6, bold: false, italic: true),
            StyleSpan(location: 26, length: 4, bold: true, italic: true),
        ])
        XCTAssertEqual(b[1].spans, [StyleSpan(location: 0, length: 8, bold: true, italic: false)])
        XCTAssertEqual(b[2].text, "abcd")
        XCTAssertEqual(b[2].spans, [StyleSpan(location: 1, length: 2, bold: true, italic: false)])
    }

    func testMultiSpineNavAndNumbering() throws {
        let book = try EPUBTestSupport.parse("multispine")
        XCTAssertEqual(book.metadata.language, "fr")
        // spine: cover.svg (1), c1 (2), c2 linear=no (3), c3 (4)
        XCTAssertEqual(book.chapters.map(\.spineIndex), [2, 3, 4])
        XCTAssertEqual(book.chapters.map(\.title), ["Un", "Deux", "Trois"])
        XCTAssertEqual(book.chapters.map { $0.blocks[0].xpointer }, ["2:p[1]@0", "3:p[1]@0", "4:p[1]@0"])
        XCTAssertEqual(book.chapters.map { $0.blocks[0].globalOffset }, [0, 3, 6])
        XCTAssertEqual(book.totalCharacters, 11)
    }

    func testEntitiesAndMalformedXHTML() throws {
        let book = try EPUBTestSupport.parse("entities")
        XCTAssertEqual(book.metadata.title, "Entities & More")
        XCTAssertEqual(book.chapters[0].blocks[0].text, "A\u{00A0}B \u{00A9} \u{00E9}t\u{00E9} \u{2014} \u{2014} A & <ok>")
        let c2 = book.chapters[1].blocks
        XCTAssertEqual(c2.map(\.text), ["Unclosed\nbreak AT&T", "Second bold", "Third"])
        XCTAssertEqual(c2[0].xpointer, "2:p[1]@0")
        XCTAssertEqual(c2[1].spans, [StyleSpan(location: 7, length: 4, bold: true, italic: false)])
    }

    func testUnicode() throws {
        let book = try EPUBTestSupport.parse("unicode")
        XCTAssertEqual(book.metadata.title, "日本語の本")
        let b = book.chapters[0].blocks
        XCTAssertEqual(b[0].text, "日本語のテキスト。")
        XCTAssertEqual(b[1].text, "Emoji \u{1F600} and e\u{0301} combining.")
        XCTAssertEqual(b[1].globalOffset, 9)
        XCTAssertEqual(book.totalCharacters, 9 + b[1].text.count)
    }

    func testBoldSpanUsesUTF16Offsets() throws {
        let html = Data("<html><body><p>\u{1F600} <b>x</b></p></body></html>".utf8)
        let blocks = BlockExtractor.extract(from: html).blocks
        XCTAssertEqual(blocks[0].spans, [StyleSpan(location: 3, length: 1, bold: true, italic: false)])
    }

    func testHTMLEntityTable() {
        XCTAssertEqual(HTMLEntities.latin1Names.count, 96)
        XCTAssertEqual(HTMLEntities.table["yuml"], 255)
    }

    // MARK: Errors and guards

    func testNotAZip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try Data("not a zip".utf8).write(to: url)
        XCTAssertThrowsError(try EPUBTestSupport.parser().process(epubAt: url)) {
            XCTAssertEqual($0 as? EPUBError, .invalidArchive)
        }
    }

    func testMissingContainer() throws {
        let url = try EPUBTestSupport.makeZip([("hello.txt", Data("x".utf8))])
        XCTAssertThrowsError(try EPUBTestSupport.parser().process(epubAt: url)) {
            XCTAssertEqual($0 as? EPUBError, .missingContainer)
        }
    }

    func testMissingPackage() throws {
        let url = try EPUBTestSupport.makeZip([("META-INF/container.xml", EPUBTestSupport.container)])
        XCTAssertThrowsError(try EPUBTestSupport.parser().process(epubAt: url)) {
            XCTAssertEqual($0 as? EPUBError, .missingPackageDocument)
        }
    }

    func testMalformedPackage() throws {
        let url = try EPUBTestSupport.makeZip([("META-INF/container.xml", EPUBTestSupport.container),
                                               ("content.opf", Data("this is not xml".utf8))])
        XCTAssertThrowsError(try EPUBTestSupport.parser().process(epubAt: url)) {
            guard case .malformedXML = $0 as? EPUBError else { return XCTFail("\($0)") }
        }
    }

    func testEmptySpine() throws {
        let url = try EPUBTestSupport.makeZip([("META-INF/container.xml", EPUBTestSupport.container),
                                               ("content.opf", EPUBTestSupport.opf(spine: []))])
        XCTAssertThrowsError(try EPUBTestSupport.parser().process(epubAt: url)) {
            XCTAssertEqual($0 as? EPUBError, .emptySpine)
        }
    }

    func testZipSlipEntriesIgnoredAndMissingChapterSkipped() throws {
        let url = try EPUBTestSupport.makeZip([
            ("META-INF/container.xml", EPUBTestSupport.container),
            ("content.opf", EPUBTestSupport.opf(spine: ["c1", "c2"])),
            ("c1.xhtml", Data("<html><body><p>Safe</p></body></html>".utf8)),
            ("../evil.xhtml", Data("<html><body><p>Evil</p></body></html>".utf8)),
        ])
        let book = try EPUBTestSupport.parser().process(epubAt: url)
        XCTAssertEqual(book.chapters.map(\.spineIndex), [1])
        XCTAssertNil(ZipReader.normalize("../evil.xhtml"))
        XCTAssertNil(ZipReader.normalize("/abs"))
        XCTAssertEqual(ZipReader.normalize("a/./b/../c.xhtml"), "a/c.xhtml")
    }

    func testOversizedEntryRejected() throws {
        let big = Data(repeating: 0x61, count: 2 * 1024 * 1024 + 1)
        let url = try EPUBTestSupport.makeZip([("big.bin", big), ("META-INF/container.xml", EPUBTestSupport.container)])
        let reader = try ZipReader(url: url, maxEntrySize: 2 * 1024 * 1024)
        XCTAssertThrowsError(try reader.data(at: "big.bin")) {
            XCTAssertEqual($0 as? EPUBError, .entryTooLarge("big.bin"))
        }
    }

    func testResolveHrefs() {
        XCTAssertEqual(EPUBParser.resolve("../text/c%201.xhtml#a", relativeTo: "OEBPS/nav/nav.xhtml"), "OEBPS/text/c 1.xhtml")
        XCTAssertNil(EPUBParser.resolve("http://example.com/x", relativeTo: "a.opf"))
        XCTAssertNil(EPUBParser.resolve("../../x", relativeTo: "a/b.opf"))
    }

    // MARK: Optional integration (Project Gutenberg etc.)

    /// Set `FOLITO_EPUB` to a path of a real EPUB to run this.
    func testRealWorldEPUBIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["FOLITO_EPUB"] else {
            throw XCTSkip("FOLITO_EPUB not set")
        }
        let book = try EPUBTestSupport.parser().process(epubAt: URL(fileURLWithPath: path))
        XCTAssertFalse(book.chapters.isEmpty)
        XCTAssertGreaterThan(book.totalCharacters, 1000)
        var expected = 0
        for ch in book.chapters { for b in ch.blocks { XCTAssertEqual(b.globalOffset, expected); expected += b.text.count } }
        XCTAssertEqual(expected, book.totalCharacters)
    }
}
