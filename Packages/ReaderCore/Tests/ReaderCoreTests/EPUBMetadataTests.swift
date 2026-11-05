import XCTest
@testable import ReaderCore

final class EPUBMetadataTests: XCTestCase {
    private func read(_ name: String) throws -> (details: EPUBDetails, cover: EPUBCover?) {
        try EPUBMetadataReader.read(epubAt: EPUBTestSupport.fixture(name))
    }

    // MARK: Cover paths

    func testCoverFromEPUB3CoverImageProperty() throws {
        let cover = try XCTUnwrap(try read("cover_epub3").cover)
        XCTAssertEqual(cover.source, .coverImageProperty)
        XCTAssertEqual(cover.path, "OEBPS/images/cover.png")
        XCTAssertEqual(cover.mediaType, "image/png")
        XCTAssertTrue(cover.isRaster)
        XCTAssertEqual(Array(cover.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testCoverFromEPUB2MetaCover() throws {
        let cover = try XCTUnwrap(try read("cover_meta").cover)
        XCTAssertEqual(cover.source, .metaCover)
        XCTAssertEqual(cover.path, "OEBPS/cover.jpg")
        XCTAssertEqual(cover.mediaType, "image/jpeg")
    }

    func testCoverFromGuideReferencePage() throws {
        let cover = try XCTUnwrap(try read("cover_guide").cover)
        XCTAssertEqual(cover.source, .guide)
        XCTAssertEqual(cover.path, "OEBPS/images/c.gif")
        XCTAssertEqual(cover.mediaType, "image/gif")
    }

    func testCoverFromFirstSpineItemSVGImage() throws {
        let cover = try XCTUnwrap(try read("cover_spine").cover)
        XCTAssertEqual(cover.source, .firstSpineItem)
        XCTAssertEqual(cover.path, "OEBPS/img/c.jpeg")
        XCTAssertEqual(cover.mediaType, "image/jpeg")
    }

    func testSVGCoverIsFoundButNotRaster() throws {
        let cover = try XCTUnwrap(try read("multispine").cover)
        XCTAssertEqual(cover.mediaType, "image/svg+xml")
        XCTAssertFalse(cover.isRaster)
    }

    func testBookWithoutImagesHasNoCover() throws {
        XCTAssertNil(try read("simple").cover)
    }

    // MARK: Metadata

    func testEPUB3Metadata() throws {
        let d = try read("cover_epub3").details
        XCTAssertEqual(d.title, "Dune Messiah")
        XCTAssertEqual(d.authors, ["Frank Herbert"])
        XCTAssertEqual(d.creators.first?.fileAs, "Herbert, Frank")
        XCTAssertEqual(d.creators.map(\.role), ["aut", "ill"])
        XCTAssertEqual(d.description, "The second book.\n\nPaul rules & doubts.")
        XCTAssertEqual(d.publisher, "Ace")
        XCTAssertEqual(d.year, 1969)
        XCTAssertEqual(d.language, "en")
        XCTAssertEqual(d.subjects, ["Science fiction", "Dune (Imaginary place)"])
        XCTAssertEqual(d.isbn, "9780441172719")
        XCTAssertEqual(d.series, BookSeries(name: "Dune", index: 2))
    }

    func testEPUB2MetadataAndCalibreSeries() throws {
        let d = try read("cover_meta").details
        XCTAssertEqual(d.authors, ["Ann Writer", "Bo Coauthor"])
        XCTAssertEqual(d.creators.first?.fileAs, "Writer, Ann")
        XCTAssertEqual(d.description, "First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(d.year, 2003, "the publication date wins over the modification date")
        XCTAssertEqual(d.language, "es")
        XCTAssertEqual(d.isbn, "0306406152")
        XCTAssertEqual(d.series, BookSeries(name: "The Tales", index: 2.5))
    }

    func testCreatorsWithoutRolesAreAllAuthors() throws {
        XCTAssertEqual(try read("cover_guide").details.authors, ["No Role"])
        XCTAssertEqual(try read("simple").details.authors, ["Jane Author", "John Coauthor"])
    }

    func testISBNFromScheme() throws {
        XCTAssertEqual(try read("simple").details.isbn, "9781234567890")
        XCTAssertNil(try read("nested").details.isbn)
    }

    func testCollectionThatIsNotASeriesIsIgnored() {
        let opf = """
        <package version="3.0"><metadata><dc:title>T</dc:title>
        <meta property="belongs-to-collection" id="s">Favourites</meta>
        <meta refines="#s" property="collection-type">set</meta></metadata></package>
        """
        let root = try! XMLTreeBuilder.parse(Data(opf.utf8), what: "opf")
        XCTAssertNil(EPUBMetadataReader.parseDetails(root, fallbackTitle: "T").series)
    }

    func testEPUB3SeriesWinsOverCalibre() {
        let opf = """
        <package version="3.0"><metadata><dc:title>T</dc:title>
        <meta name="calibre:series" content="Old"/><meta name="calibre:series_index" content="9"/>
        <meta property="belongs-to-collection" id="s">New</meta>
        <meta refines="#s" property="collection-type">series</meta></metadata></package>
        """
        let root = try! XMLTreeBuilder.parse(Data(opf.utf8), what: "opf")
        XCTAssertEqual(EPUBMetadataReader.parseDetails(root, fallbackTitle: "T").series, BookSeries(name: "New", index: nil))
    }

    func testYearParsing() {
        XCTAssertEqual(EPUBMetadataReader.year(from: "2019-05-01"), 2019)
        XCTAssertEqual(EPUBMetadataReader.year(from: "1813"), 1813)
        XCTAssertEqual(EPUBMetadataReader.year(from: "2001-01-01T00:00:00+00:00"), 2001)
        XCTAssertNil(EPUBMetadataReader.year(from: "0101-01-01"))
        XCTAssertNil(EPUBMetadataReader.year(from: "unknown"))
    }

    func testISBNValidation() {
        XCTAssertTrue(EPUBMetadataReader.isValidISBN("9780441172719"))
        XCTAssertTrue(EPUBMetadataReader.isValidISBN("080442957X"))
        XCTAssertFalse(EPUBMetadataReader.isValidISBN("9780441172718"))
        XCTAssertFalse(EPUBMetadataReader.isValidISBN("1234"))
    }

    func testPlainTextFromHTML() {
        XCTAssertEqual(EPUBMetadataReader.plainText(fromHTML: "<div><p>One <i>two</i></p><p>Three&nbsp;four</p></div>"),
                       "One two\n\nThree four")
        XCTAssertEqual(EPUBMetadataReader.plainText(fromHTML: "Line one<br/>Line two"), "Line one\n\nLine two")
        XCTAssertEqual(EPUBMetadataReader.plainText(fromHTML: "  just   text  "), "just text")
    }

    // MARK: Placeholder colours and excerpts

    func testCoverPaletteIsStableAndReadable() {
        XCTAssertEqual(CoverPalette.index(for: "Dune"), CoverPalette.index(for: "  dune "))
        let indices = Set(["Dune", "Emma", "Ulysses", "Moby-Dick", "Frankenstein", "Dracula", "Persuasion", "Kim"]
            .map(CoverPalette.index(for:)))
        XCTAssertGreaterThan(indices.count, 2, "titles spread over the palette")
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        for color in CoverPalette.colors {
            let r = linear(Double((color >> 16) & 0xFF) / 255), g = linear(Double((color >> 8) & 0xFF) / 255)
            let b = linear(Double(color & 0xFF) / 255)
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 6, String(color, radix: 16))
        }
    }

    func testExcerpt() {
        let short = DescriptionExcerpt.excerpt("Short text.", maxCharacters: 50)
        XCTAssertEqual(short.text, "Short text.")
        XCTAssertFalse(short.truncated)
        let long = DescriptionExcerpt.excerpt("The quick brown fox, jumps over the lazy dog", maxCharacters: 20)
        XCTAssertEqual(long.text, "The quick brown fox\u{2026}")
        XCTAssertTrue(long.truncated)
    }
}
