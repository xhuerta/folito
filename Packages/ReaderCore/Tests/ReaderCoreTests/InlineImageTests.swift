import XCTest
@testable import ReaderCore

/// Images inside the text (#71): extraction, decoration, the repeated cover, alt text and the size cap.
final class InlineImageTests: XCTestCase {
    private func parser(limits: ImageLimits = .watch, preparer: ImagePreparing = PassthroughImagePreparer()) -> EPUBParser {
        EPUBParser(identity: FakeIdentity(), xpointers: FakeXPointers(), imagePreparer: preparer, imageLimits: limits)
    }

    private func xhtml(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>\(body)</body></html>
        """.utf8)
    }

    /// A one-chapter book with `pictures` (archive path -> bytes) next to `c1.xhtml`.
    private func book(_ body: String, pictures: [String: Data] = [:], parser: EPUBParser? = nil) throws -> ProcessedBook {
        var entries: [(String, Data)] = [("META-INF/container.xml", EPUBTestSupport.container),
                                         ("content.opf", EPUBTestSupport.opf()), ("c1.xhtml", xhtml(body))]
        entries += pictures.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return try (parser ?? self.parser()).process(epubAt: try EPUBTestSupport.makeZip(entries))
    }

    /// The header of a PNG of `w` x `h` (enough for `ImageHeader` and the passthrough preparer).
    static func png(_ w: Int, _ h: Int, padding: Int = 0) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        for v in [w, h] { d += [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        d += [8, 2, 0, 0, 0]
        d += Data(repeating: 0, count: padding)
        return d
    }

    // MARK: - The illustrated fixture

    func testIllustratedFixture() throws {
        let book = try EPUBTestSupport.parser().process(epubAt: EPUBTestSupport.fixture("illustrated"))
        XCTAssertEqual(book.chapters.map(\.spineIndex), [2, 3], "the cover page holds only the cover: no chapter")
        let blocks = book.chapters[0].blocks
        XCTAssertEqual(blocks.map(\.text), [
            "Chapter One", "Before the picture.", "", "A note in his hand:", "", "as written.", "", "", "", "",
            "After the pictures.",
        ])
        let images = blocks.map(\.image)
        XCTAssertEqual(images[2], BlockImage(id: "i1", width: 400, height: 300, alt: "The word Earth, drawn as an ambigram"),
                       "alt text is whitespace-collapsed")
        XCTAssertEqual(images[4], BlockImage(id: "i2", width: 500, height: 200, alt: nil), "an image inside a paragraph splits it")
        XCTAssertEqual(images[6], BlockImage(id: "i3", width: 200, height: 150, alt: nil),
                       "an image with an empty alt inside a link is kept")
        XCTAssertEqual(images[7], BlockImage(id: nil, alt: "A diagram of the four elements"), "SVG: the alt text")
        XCTAssertEqual(images[8], BlockImage(id: nil, alt: "A damaged picture"), "undecodable: the alt text")
        XCTAssertEqual(images[9], BlockImage(id: "i4", width: 300, height: 400, alt: nil), "an SVG <image> is kept")
        XCTAssertEqual(blocks[2].xpointer, "2:div[1]/img[1]@-", "an image's XPointer names the element")
        XCTAssertEqual(blocks[9].xpointer, "2:svg[1]@-")
        XCTAssertEqual(book.images?.map(\.id), ["i1", "i2", "i3", "i4"])
        XCTAssertEqual(book.images?.map(\.width), [400, 500, 200, 300])
        XCTAssertEqual(book.images?.first?.mediaType, "image/png")
        // Images add no characters.
        let texts = book.chapters.flatMap(\.blocks).map(\.text)
        XCTAssertEqual(book.totalCharacters, texts.reduce(0) { $0 + $1.count })
        var expected = 0
        for block in book.chapters.flatMap(\.blocks) {
            XCTAssertEqual(block.globalOffset, expected)
            expected += block.text.count
        }
        XCTAssertEqual(book.formatVersion, 1)
    }

    // MARK: - Extraction

    func testImageBetweenParagraphsKeepsItsPlace() throws {
        let b = try book("<p>One.</p><p><img src=\"a.png\" alt=\"A map\"/></p><p>Two.</p>", pictures: ["a.png": Self.png(640, 480)])
        XCTAssertEqual(b.chapters[0].blocks.map(\.text), ["One.", "", "Two."])
        XCTAssertEqual(b.chapters[0].blocks[1].image, BlockImage(id: "i1", width: 640, height: 480, alt: "A map"))
        XCTAssertTrue(b.chapters[0].blocks[1].isImage)
        XCTAssertFalse(b.chapters[0].blocks[0].isImage)
        XCTAssertEqual(b.images?.first?.data, Self.png(640, 480))
    }

    func testTheSamePictureTwiceIsStoredOnce() throws {
        let b = try book("<p>t</p><p><img src=\"a.png\" alt=\"x\"/></p><p>t</p><p><img src=\"a.png\" alt=\"y\"/></p>",
                         pictures: ["a.png": Self.png(400, 400)])
        XCTAssertEqual(b.images?.count, 1)
        XCTAssertEqual(b.chapters[0].blocks.compactMap(\.image?.id), ["i1", "i1"])
        XCTAssertEqual(b.chapters[0].blocks.compactMap(\.image?.alt), ["x", "y"])
    }

    func testIdOnAnImageResolvesToItsBlock() throws {
        let (blocks, anchors) = BlockExtractor.extract(from: xhtml("<p>Text <img id=\"f\" src=\"a.png\"/> more</p>"),
                                                       wantedIDs: ["f"])
        XCTAssertEqual(blocks.map(\.text), ["Text", "", "more"])
        XCTAssertEqual(anchors["f"], AnchorTarget(blockIndex: 1, characterOffset: 0))
    }

    func testImageInsideANoteStaysOut() throws {
        let (blocks, _) = BlockExtractor.extract(from: xhtml(
            "<p>a</p><aside epub:type=\"footnote\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><p>n <img src=\"a.png\"/></p></aside>"),
            wantedIDs: [])
        XCTAssertNil(blocks.first { $0.image != nil })
    }

    func testDroppingMovesAnchorsToTheNextBlock() {
        let raw = ["a", "", "b"].map { RawBlock(text: $0, style: .paragraph, spans: [], path: []) }
        let out = EPUBParser.dropping([1], from: raw, anchors: ["x": AnchorTarget(blockIndex: 1, characterOffset: 0),
                                                                "y": AnchorTarget(blockIndex: 2, characterOffset: 1),
                                                                "z": AnchorTarget(blockIndex: 3, characterOffset: 0)])
        XCTAssertEqual(out.blocks.map(\.text), ["a", "b"])
        XCTAssertEqual(out.anchors["x"], AnchorTarget(blockIndex: 1, characterOffset: 0))
        XCTAssertEqual(out.anchors["y"], AnchorTarget(blockIndex: 1, characterOffset: 1))
        XCTAssertEqual(out.anchors["z"], AnchorTarget(blockIndex: 2, characterOffset: 0))
    }

    func testExternalPictureKeepsOnlyItsDescription() throws {
        let b = try book("<p>t</p><p><img src=\"https://example.com/a.png\" alt=\"Remote\"/></p>")
        XCTAssertEqual(b.chapters[0].blocks[1].image, BlockImage(id: nil, alt: "Remote"))
        XCTAssertNil(b.images)
    }

    func testMissingFileWithoutAltLeavesNothing() throws {
        let b = try book("<p>t</p><p><img src=\"gone.png\"/></p><p><img src=\"gone.png\" alt=\"Said\"/></p>")
        XCTAssertEqual(b.chapters[0].blocks.map(\.image), [nil, BlockImage(id: nil, alt: "Said")])
    }

    // MARK: - Decoration

    func testDecorativeImagesAreSkipped() throws {
        let b = try book("""
        <p>t</p>
        <p><img src="orn.png" alt="ornament"/></p>
        <p><img src="rule.png" alt="rule"/></p>
        <p><img src="small.png" alt=""/></p>
        <p><img src="big.png" alt="" width="20" height="20"/></p>
        <p><img src="big.png" aria-hidden="true"/></p>
        """, pictures: ["orn.png": Self.png(40, 40), "rule.png": Self.png(800, 10), "small.png": Self.png(300, 200),
                        "big.png": Self.png(900, 700)])
        XCTAssertEqual(b.chapters[0].blocks.map(\.text), ["t"])
        XCTAssertNil(b.images)
    }

    func testFilterRules() {
        func deco(_ w: Int?, _ h: Int?, alt: String?, link: Bool = false, presentational: Bool = false) -> Bool {
            let size = w.flatMap { w in h.map { PixelSize(width: w, height: $0) } }
            return ImageFilter.isDecorative(size: size, alt: alt, inLink: link, presentational: presentational)
        }
        XCTAssertTrue(deco(47, 47, alt: "x"), "ornament")
        XCTAssertFalse(deco(48, 48, alt: "x"))
        XCTAssertTrue(deco(600, 24, alt: "x"), "separator")
        XCTAssertFalse(deco(600, 100, alt: "x"))
        XCTAssertFalse(deco(100, 24, alt: "x"), "short and thick: not a rule")
        XCTAssertTrue(deco(320, 200, alt: ""), "empty alt, no link")
        XCTAssertTrue(deco(320, 200, alt: "  "))
        XCTAssertFalse(deco(321, 200, alt: ""), "a large picture with an empty alt is kept")
        XCTAssertFalse(deco(200, 200, alt: "", link: true), "inside a link")
        XCTAssertFalse(deco(200, 200, alt: nil), "no alt attribute at all")
        XCTAssertTrue(deco(nil, nil, alt: ""), "unknown size, empty alt: nothing to show")
        XCTAssertFalse(deco(nil, nil, alt: nil))
        XCTAssertTrue(deco(1000, 1000, alt: "x", presentational: true))
        XCTAssertEqual(ImageFilter.declaredPixels("120px"), 120)
        XCTAssertEqual(ImageFilter.declaredPixels(" 64 "), 64)
        XCTAssertNil(ImageFilter.declaredPixels("50%"))
        XCTAssertNil(ImageFilter.declaredPixels("2em"))
    }

    // MARK: - The cover

    func testDeclaredCoverIsSkippedEverywhere() throws {
        let opf = EPUBTestSupport.opf(spine: ["c1", "c2"],
                                      manifestExtra: "<item id=\"cv\" href=\"cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>")
        let url = try EPUBTestSupport.makeZip([
            ("META-INF/container.xml", EPUBTestSupport.container), ("content.opf", opf),
            ("c1.xhtml", xhtml("<p><img src=\"cover.png\" alt=\"Cover\"/></p><p>Title page</p>")),
            ("c2.xhtml", xhtml("<p>Text</p><p><img src=\"cover.png\" alt=\"Cover\"/></p>")),
            ("cover.png", Self.png(600, 900)),
        ])
        let b = try parser().process(epubAt: url)
        XCTAssertEqual(b.chapters.flatMap(\.blocks).map(\.text), ["Title page", "Text"])
        XCTAssertNil(b.images)
    }

    func testGuessedCoverIsSkippedOnTheFirstPageOnly() throws {
        let url = try EPUBTestSupport.makeZip([
            ("META-INF/container.xml", EPUBTestSupport.container), ("content.opf", EPUBTestSupport.opf(spine: ["c1", "c2"])),
            ("c1.xhtml", xhtml("<p><img src=\"art.png\" alt=\"Art\"/></p><p>Title page</p>")),
            ("c2.xhtml", xhtml("<p>Text</p><p><img src=\"art.png\" alt=\"Art\"/></p>")),
            ("art.png", Self.png(600, 900)),
        ])
        let b = try parser().process(epubAt: url)
        XCTAssertEqual(b.chapters[0].blocks.map(\.text), ["Title page"])
        XCTAssertEqual(b.chapters[1].blocks.map(\.image?.id), [nil, "i1"])
    }

    // MARK: - Size cap

    /// Bytes proportional to the requested size: `bytesPerPixel` per pixel of the longer side.
    private struct SizedPreparer: ImagePreparing {
        var bytesPerPixel: Int
        func prepare(_ data: Data, mediaType: String, maxPixels: Int) -> PreparedImage? {
            guard let size = ImageHeader.pixelSize(of: data) else { return nil }
            let scale = min(1, Double(maxPixels) / Double(size.longerSide))
            let w = Int((Double(size.width) * scale).rounded()), h = Int((Double(size.height) * scale).rounded())
            return PreparedImage(data: Data(count: max(w, h) * bytesPerPixel), mediaType: "image/jpeg", width: w, height: h)
        }
    }

    func testPicturesAreResizedToTheLimit() throws {
        let b = try book("<p>t</p><p><img src=\"a.png\" alt=\"A\"/></p>", pictures: ["a.png": Self.png(4000, 3000)],
                         parser: parser(limits: ImageLimits(maxPixels: 1248, reducedMaxPixels: 832, maxImageBytes: 1_000_000,
                                                            maxTotalBytes: 10_000_000),
                                        preparer: SizedPreparer(bytesPerPixel: 10)))
        XCTAssertEqual(b.images?.first.map { PixelSize(width: $0.width, height: $0.height) }, PixelSize(width: 1248, height: 936))
        XCTAssertEqual(b.chapters[0].blocks[1].image?.width, 1248)
        XCTAssertEqual(b.images?.first?.mediaType, "image/jpeg")
    }

    func testHeavyPictureIsTriedSmaller() {
        var e = ImageEmbedder(preparer: SizedPreparer(bytesPerPixel: 100),
                              limits: ImageLimits(maxPixels: 1000, reducedMaxPixels: 500, maxImageBytes: 60_000,
                                                  maxTotalBytes: 1_000_000))
        let kept = e.embed(path: "a", data: Self.png(2000, 2000), mediaType: "image/png")
        XCTAssertEqual(kept?.width, 500, "100 KB at 1000 px is over the per-picture limit; 50 KB at 500 px fits")
        var tight = ImageEmbedder(preparer: SizedPreparer(bytesPerPixel: 100),
                                  limits: ImageLimits(maxPixels: 1000, reducedMaxPixels: 500, maxImageBytes: 10_000,
                                                      maxTotalBytes: 1_000_000))
        XCTAssertNil(tight.embed(path: "a", data: Self.png(2000, 2000), mediaType: "image/png"))
        XCTAssertTrue(tight.wasRefused("a"))
    }

    func testTotalCapKeepsTheFirstPicturesAndShrinksTheRest() {
        var e = ImageEmbedder(preparer: SizedPreparer(bytesPerPixel: 100),
                              limits: ImageLimits(maxPixels: 1000, reducedMaxPixels: 500, maxImageBytes: 100_000,
                                                  maxTotalBytes: 300_000))
        var widths: [Int?] = []
        for i in 0..<6 { widths.append(e.embed(path: "p\(i)", data: Self.png(2000, 2000), mediaType: "image/png")?.width) }
        // 100 KB, then past half the budget 50 KB each, until 300 KB.
        XCTAssertEqual(widths, [1000, 1000, 500, 500, nil, nil])
        XCTAssertEqual(e.totalBytes, 300_000)
        XCTAssertLessThanOrEqual(e.totalBytes, 300_000)
        XCTAssertEqual(e.images.map(\.id), ["i1", "i2", "i3", "i4"])
    }

    func testPictureOverTheCapShowsItsAltText() throws {
        let b = try book("<p>t</p><p><img src=\"a.png\" alt=\"First\"/></p><p><img src=\"b.png\" alt=\"Second\"/></p>",
                         pictures: ["a.png": Self.png(1000, 1000), "b.png": Self.png(1000, 1000)],
                         parser: parser(limits: ImageLimits(maxPixels: 1000, reducedMaxPixels: 1000, maxImageBytes: 100_000,
                                                            maxTotalBytes: 150_000),
                                        preparer: SizedPreparer(bytesPerPixel: 100)))
        XCTAssertEqual(b.chapters[0].blocks.map(\.image), [nil, BlockImage(id: "i1", width: 1000, height: 1000, alt: "First"),
                                                           BlockImage(id: nil, alt: "Second")])
        XCTAssertEqual(b.images?.count, 1)
    }

    func testPassthroughRefusesWhatItCannotResize() {
        let p = PassthroughImagePreparer()
        XCTAssertNotNil(p.prepare(Self.png(800, 600), mediaType: "image/png", maxPixels: 1248))
        XCTAssertNil(p.prepare(Self.png(2000, 600), mediaType: "image/png", maxPixels: 1248))
        XCTAssertNil(p.prepare(Data("<svg/>".utf8), mediaType: "image/svg+xml", maxPixels: 1248))
    }

    // MARK: - Headers

    func testHeaderSizes() {
        XCTAssertEqual(ImageHeader.pixelSize(of: Self.png(123, 45)), PixelSize(width: 123, height: 45))
        XCTAssertEqual(ImageHeader.pixelSize(of: Data("GIF89a".utf8) + Data([0x40, 0x01, 0xF0, 0x00])),
                       PixelSize(width: 320, height: 240))
        // SOI, an APP0 segment, then SOF0 (precision 8, height 0x01E0, width 0x0280).
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0xE0, 0x02, 0x80, 0x03])
        XCTAssertEqual(ImageHeader.pixelSize(of: jpeg), PixelSize(width: 640, height: 480))
        var webp = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBPVP8X".utf8) + Data(repeating: 0, count: 8)
        webp += Data([0x1F, 0x03, 0x00, 0xDF, 0x01, 0x00])  // 799 + 1, 479 + 1
        XCTAssertEqual(ImageHeader.pixelSize(of: webp), PixelSize(width: 800, height: 480))
        var bmp = Data("BM".utf8) + Data(repeating: 0, count: 16)
        bmp += Data([0x64, 0, 0, 0, 0x38, 0xFF, 0xFF, 0xFF])  // 100, -200 (top-down)
        XCTAssertEqual(ImageHeader.pixelSize(of: bmp), PixelSize(width: 100, height: 200))
        XCTAssertNil(ImageHeader.pixelSize(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x66, 0x69])), "damaged JPEG")
        XCTAssertNil(ImageHeader.pixelSize(of: Data("<svg/>".utf8)))
        XCTAssertNil(ImageHeader.pixelSize(of: Data()))
    }

    // MARK: - Format compatibility

    func testBooksWithoutImagesDecodeAndNewKeysAreOptional() throws {
        let old = Data(#"{"text":"a","style":"paragraph","spans":[],"xpointer":"x","globalOffset":0}"#.utf8)
        let block = try JSONDecoder().decode(Block.self, from: old)
        XCTAssertNil(block.image)
        let image = Block(text: "", xpointer: "x", globalOffset: 0, image: BlockImage(id: "i1", width: 2, height: 1, alt: "A"))
        let round = try JSONDecoder().decode(Block.self, from: JSONEncoder().encode(image))
        XCTAssertEqual(round, image)
        XCTAssertEqual(round.image?.aspectRatio, 2)
        let book = ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "m",
                                 chapters: [Chapter(spineIndex: 1, title: nil, blocks: [image])], totalCharacters: 0,
                                 images: [BookImage(id: "i1", mediaType: "image/jpeg", width: 2, height: 1, data: Data([1, 2]))])
        let decoded = try JSONDecoder().decode(ProcessedBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(decoded, book)
        XCTAssertEqual(decoded.formatVersion, 1, "older watch builds ignore the new keys")
    }
}
