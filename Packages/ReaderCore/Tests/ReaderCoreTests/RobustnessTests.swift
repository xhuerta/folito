import XCTest
import ZIPFoundation
@testable import ReaderCore

/// Hostile / broken input: the parser must throw a typed `EPUBError` (or succeed), never crash or hang.
final class RobustnessTests: XCTestCase {
    typealias Entry = (String, Data)

    /// Runs `process` on a background thread with a deadline; returns the outcome.
    @discardableResult
    func run(_ url: URL, timeout: TimeInterval = 20, label: String = "",
             file: StaticString = #filePath, line: UInt = #line) -> Result<ProcessedBook, Error>? {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<ProcessedBook, Error>?
        let thread = Thread {
            outcome = Result { try EPUBParser().process(epubAt: url) }
            sem.signal()
        }
        thread.stackSize = 512 * 1024   // closer to a watch/secondary-thread stack than the 8MB main stack
        thread.start()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            XCTFail("\(label): parser did not finish in \(timeout)s", file: file, line: line)
            return nil
        }
        if case .failure(let e)? = outcome, !(e is EPUBError) {
            XCTFail("\(label): untyped error \(e)", file: file, line: line)
        }
        return outcome
    }

    func zip(_ extra: [Entry], opf: Data = EPUBTestSupport.opf(), skipContainer: Bool = false) throws -> URL {
        var entries: [Entry] = []
        if !skipContainer { entries.append(("META-INF/container.xml", EPUBTestSupport.container)) }
        entries.append(("content.opf", opf))
        entries.append(contentsOf: extra)
        return try EPUBTestSupport.makeZip(entries)
    }

    func xhtml(_ body: String) -> Data {
        Data("<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>t</title></head><body>\(body)</body></html>".utf8)
    }

    // MARK: Broken containers

    func testNotAZipAndEmptyAndTinyFiles() throws {
        for (i, bytes) in [Data(), Data([0x50]), Data("PK\u{3}\u{4}".utf8), Data(repeating: 0, count: 100),
                           Data("hello world, definitely not a zip".utf8)].enumerated() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).epub")
            try bytes.write(to: url)
            guard case .failure(let e)? = run(url, label: "garbage \(i)") else { XCTFail("garbage \(i) parsed"); continue }
            XCTAssertEqual(e as? EPUBError, .invalidArchive, "garbage \(i)")
        }
    }

    func testMissingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID()).epub")
        guard case .failure(let e)? = run(url) else { return XCTFail() }
        XCTAssertTrue(e is EPUBError)
    }

    func testDirectoryInsteadOfFile() {
        guard case .failure(let e)? = run(FileManager.default.temporaryDirectory) else { return XCTFail() }
        XCTAssertEqual(e as? EPUBError, .invalidArchive)
    }

    func testTruncatedEPUBsAtManyLengths() throws {
        let original = try Data(contentsOf: EPUBTestSupport.fixture("multispine"))
        var lengths = Set(stride(from: 0, to: original.count, by: max(1, original.count / 60)))
        lengths.formUnion([1, 3, 4, 21, 22, original.count - 1, original.count - 22, original.count - 23])
        var ok = 0, failed = 0
        for n in lengths.sorted() where n < original.count {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).epub")
            try original.prefix(n).write(to: url)
            switch run(url, label: "truncated \(n)") {
            case .success?: ok += 1
            case .failure?: failed += 1
            case nil: return
            }
        }
        XCTAssertGreaterThan(failed, 0)
        print("truncation: \(ok) parsed, \(failed) rejected")
    }

    /// Deterministic byte-flip fuzzing of real fixtures.
    func testByteFlipFuzzing() throws {
        var rng = SplitMix(seed: 0xC0FFEE)
        for name in ["simple", "multispine", "entities", "unicode", "nested", "inline"] {
            let original = try Data(contentsOf: EPUBTestSupport.fixture(name))
            for round in 0..<25 {
                var d = original
                for _ in 0..<(1 + round % 8) { d[Int(rng.next() % UInt64(d.count))] = UInt8(truncatingIfNeeded: rng.next()) }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).epub")
                try d.write(to: url)
                if run(url, label: "\(name)#\(round)") == nil { return }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func testMissingContainerAndMissingOPFAndBadRootfile() throws {
        guard case .failure(let e1)? = run(try zip([("c1.xhtml", xhtml("<p>x</p>"))], skipContainer: true)) else { return XCTFail() }
        XCTAssertEqual(e1 as? EPUBError, .missingContainer)

        let noOPF = try EPUBTestSupport.makeZip([("META-INF/container.xml", EPUBTestSupport.container), ("c1.xhtml", xhtml("<p>x</p>"))])
        guard case .failure(let e2)? = run(noOPF) else { return XCTFail() }
        XCTAssertEqual(e2 as? EPUBError, .missingPackageDocument)

        for bad in ["", "<container/>", "<container><rootfiles/></container>",
                    "<container><rootfiles><rootfile/></rootfiles></container>",
                    "<container><rootfiles><rootfile full-path='../../etc/passwd'/></rootfiles></container>",
                    "<container><rootfiles><rootfile full-path='/abs.opf'/></rootfiles></container>",
                    "<container><rootfiles><rootfile full-path='a\\b.opf'/></rootfiles></container>"] {
            let url = try EPUBTestSupport.makeZip([("META-INF/container.xml", Data(bad.utf8)), ("content.opf", EPUBTestSupport.opf())])
            guard case .failure(let e)? = run(url, label: bad) else { XCTFail("accepted \(bad)"); continue }
            XCTAssertTrue(e is EPUBError)
        }
    }

    func testOPFVariants() throws {
        // rootfile pointing at a non-package document, spine referencing unknown ids, no metadata, no manifest.
        let variants: [(String, String, EPUBError?)] = [
            ("html root", "<html><body>hi</body></html>", .malformedXML("")),
            ("no spine", "<package><metadata/><manifest/></package>", .emptySpine),
            ("dangling itemrefs", "<package><manifest/><spine><itemref idref='x'/><itemref/></spine></package>", .emptySpine),
            ("itemref without manifest", "<package><spine><itemref idref='c1'/></spine></package>", .emptySpine),
        ]
        for (label, opf, expected) in variants {
            let url = try zip([("c1.xhtml", xhtml("<p>x</p>"))], opf: Data(opf.utf8))
            guard case .failure(let e)? = run(url, label: label) else { XCTFail("\(label) parsed"); continue }
            if case .malformedXML? = expected { if case .malformedXML = e as? EPUBError ?? .emptySpine {} else { XCTFail("\(label): \(e)") } }
            else { XCTAssertEqual(e as? EPUBError, expected, label) }
        }
    }

    func testSpineOnlyNonTextOrMissingItemsYieldsEmptyBookNotCrash() throws {
        let opf = Data("""
        <package><metadata><title>T</title></metadata><manifest>
        <item id="a" href="gone.xhtml" media-type="application/xhtml+xml"/>
        <item id="b" href="img.png" media-type="image/png"/>
        <item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
        </manifest><spine><itemref idref="a"/><itemref idref="b"/><itemref idref="c"/></spine></package>
        """.utf8)
        let url = try zip([("img.png", Data([1, 2, 3])), ("c.xhtml", xhtml("<div> </div>"))], opf: opf)
        guard case .success(let book)? = run(url) else { return XCTFail() }
        XCTAssertTrue(book.chapters.isEmpty)
        XCTAssertEqual(book.totalCharacters, 0)
    }

    // MARK: Zip bombs and huge inputs

    func testDeclaredSizeLiesAreHandled() throws {
        // Patch the uncompressed size of a stored entry in the central directory + local header to a huge value.
        let url = try zip([("c1.xhtml", xhtml("<p>hello</p>"))])
        var d = try Data(contentsOf: url)
        let big: UInt32 = 0x7FFF_FFFF
        func patch(signature: [UInt8], sizeOffset: Int) {
            var i = 0
            while i + 4 < d.count {
                if Array(d[i..<i + 4]) == signature {
                    withUnsafeBytes(of: big.littleEndian) { for (k, b) in $0.enumerated() { d[i + sizeOffset + k] = b } }
                }
                i += 1
            }
        }
        patch(signature: [0x50, 0x4B, 0x01, 0x02], sizeOffset: 24)  // central directory: uncompressed size
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).epub")
        try d.write(to: bad)
        run(bad, label: "lying central directory")
    }

    func testHighlyCompressibleBombIsBounded() throws {
        guard ProcessInfo.processInfo.environment["FOLITO_HEAVY"] != nil else { throw XCTSkip("FOLITO_HEAVY not set (~15s)") }
        // 100 MB of 'a' compresses to ~100KB; per-entry limit is 64MB so the entry must be refused.
        let bomb = Data(repeating: 0x61, count: 100 * 1024 * 1024)
        let url = try zip([("c1.xhtml", Data("<html><body><p>".utf8) + bomb + Data("</p></body></html>".utf8))])
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertLessThan(size, 1_000_000)
        guard case .success(let book)? = run(url, timeout: 60, label: "bomb") else { return }
        // A chapter that is too large is skipped, not fatal.
        XCTAssertTrue(book.chapters.isEmpty)
    }

    func testTotalDecompressionBudget() throws {
        // Many individually acceptable entries must not add up to an unbounded amount of work.
        let chunk = Data(repeating: 0x61, count: 100_000)
        let ids = (1...10).map { "c\($0)" }
        let url = try EPUBTestSupport.makeZip([("META-INF/container.xml", EPUBTestSupport.container),
                                               ("content.opf", EPUBTestSupport.opf(spine: ids))]
                                              + ids.map { ("\($0).xhtml", Data("<html><body><p>".utf8) + chunk + Data("</p></body></html>".utf8)) })
        let reader = try ZipReader(url: url, maxEntrySize: 1_000_000, maxTotalSize: 450_000)
        var served = 0
        XCTAssertThrowsError(try { for id in ids { _ = try reader.data(at: "\(id).xhtml"); served += 1 } }()) {
            XCTAssertEqual($0 as? EPUBError, .archiveTooLarge)
        }
        XCTAssertEqual(served, 4)
    }

    func testManyEntries() throws {
        var entries: [Entry] = [("META-INF/container.xml", EPUBTestSupport.container), ("content.opf", EPUBTestSupport.opf())]
        for i in 0..<ZipReader.maxEntryCount + 5 { entries.append(("f\(i).txt", Data())) }
        let url = try EPUBTestSupport.makeZip(entries)
        guard case .failure(let e)? = run(url, timeout: 60) else { return XCTFail() }
        XCTAssertEqual(e as? EPUBError, .invalidArchive)
    }

    func testThousandsOfSpineItems() throws {
        let ids = (1...3000).map { "c\($0)" }
        let url = try EPUBTestSupport.makeZip([("META-INF/container.xml", EPUBTestSupport.container),
                                               ("content.opf", EPUBTestSupport.opf(spine: ids))]
                                              + ids.map { ("\($0).xhtml", xhtml("<p>chapter \($0)</p>")) })
        guard case .success(let book)? = run(url, timeout: 60) else { return XCTFail() }
        XCTAssertEqual(book.chapters.count, 3000)
    }

    // MARK: Hostile XML

    func parseChapter(_ data: Data, timeout: TimeInterval = 30, label: String) throws -> ProcessedBook? {
        let url = try zip([("c1.xhtml", data)])
        guard case .success(let b)? = run(url, timeout: timeout, label: label) else { return nil }
        return b
    }

    func testBillionLaughsAndExternalEntities() throws {
        let laughs = """
        <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
        <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
        <!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">
        <!ENTITY lol6 "&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;">
        <!ENTITY lol7 "&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;">
        <!ENTITY lol8 "&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;">
        <!ENTITY lol9 "&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;">]>
        <html><body><p>&lol9;</p></body></html>
        """
        let b = try parseChapter(Data(laughs.utf8), label: "billion laughs")
        XCTAssertLessThan(b?.totalCharacters ?? 0, 1000)

        let xxe = #"<?xml version="1.0"?><!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/passwd">]><html><body><p>a&x;b</p></body></html>"#
        let b2 = try parseChapter(Data(xxe.utf8), label: "xxe")
        XCTAssertFalse(b2?.chapters.first?.blocks.first?.text.contains("root:") ?? false)
    }

    func testWeirdEntities() throws {
        let body = "<p>a&#0;b&#x110000;c&#xD800;d&#99999999999;e&#xZZ;f&unknown;g&amp;h&;i&#;j&nbsp;k&#x1F600;l&amp</p><p>&lt;tag&gt; &quot;q&quot; &apos;</p>"
        guard let b = try parseChapter(xhtml(body), label: "entities") else { return XCTFail() }
        let texts = b.chapters.first?.blocks.map(\.text) ?? []
        XCTAssertEqual(texts.count, 2)
        XCTAssertTrue(texts[0].contains("😀"))
        XCTAssertFalse(texts[0].contains("\u{0}"))
        XCTAssertEqual(texts[1], "<tag> \"q\" '")
    }

    func testDeeplyNestedXHTML() throws {
        for depth in [200, 1_000, 50_000, 300_000] {
            let open = String(repeating: "<div>", count: depth), close = String(repeating: "</div>", count: depth)
            let started = Date()
                let b = try parseChapter(xhtml(open + "<p>deep</p>" + close), timeout: 60, label: "xhtml depth \(depth)")
            XCTAssertEqual(b?.chapters.first?.blocks.first?.text, "deep")
            print("depth \(depth) xhtml: \(Date().timeIntervalSince(started))s")
        }
    }

    func testDeeplyNestedOPFAndContainer() throws {
        for depth in [500, 100_000] {
            let nest = String(repeating: "<x>", count: depth) + String(repeating: "</x>", count: depth)
            let opf = Data("<package><metadata>\(nest)</metadata><manifest><item id='c1' href='c1.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='c1'/></spine></package>".utf8)
            let url = try zip([("c1.xhtml", xhtml("<p>x</p>"))], opf: opf)
            run(url, timeout: 60, label: "opf depth \(depth)")
        }
    }

    func testManyAttributesAndHugeTextNode() throws {
        let attrs = (0..<20_000).map { "a\($0)='v'" }.joined(separator: " ")
        _ = try parseChapter(xhtml("<p \(attrs)>x</p>"), label: "many attrs")
        let text = String(repeating: "word ", count: 400_000)   // 2MB single block
        let started = Date()
        let b = try parseChapter(xhtml("<p>\(text)</p>"), timeout: 60, label: "huge text")
        XCTAssertEqual(b?.chapters.first?.blocks.count, 1)
        print("2MB single paragraph: \(Date().timeIntervalSince(started))s")
    }

    func testTagSoupLenientPathPerformance() throws {
        // Not well-formed => lenient reader. Lots of PIs/doctype-like constructs and unclosed tags.
        let junk = String(repeating: "<?x y?><!foo><br><p>para text <b>bold <i>both</b> end", count: 20_000)
        let started = Date()
        let b = try parseChapter(Data("<html><body>\(junk)</body>".utf8), timeout: 60, label: "tag soup")
        XCTAssertGreaterThan(b?.totalCharacters ?? 0, 0)
        print("tag soup: \(Date().timeIntervalSince(started))s")
    }

    func testEncodings() throws {
        let text = "<html><body><p>Zoë – 日本語 — ✓</p></body></html>"
        // UTF-16 LE/BE with BOM, UTF-8 BOM, Latin-1 declared, invalid UTF-8 bytes.
        var variants: [(String, Data)] = []
        variants.append(("utf16le", Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!))
        variants.append(("utf16be", Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!))
        variants.append(("utf8bom", Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)))
        variants.append(("latin1", Data("<?xml version=\"1.0\" encoding=\"iso-8859-1\"?><html><body><p>Zo\u{EB} caf\u{E9}</p></body></html>".unicodeScalars.map { UInt8($0.value) })))
        variants.append(("invalid", Data("<html><body><p>ok ".utf8) + Data([0xFF, 0xFE, 0xC0, 0x80]) + Data(" ok</p></body></html>".utf8)))
        for (label, data) in variants {
            guard let b = try parseChapter(data, label: label) else { XCTFail(label); continue }
            XCTAssertEqual(b.chapters.count, 1, label)
            XCTAssertFalse(b.chapters[0].blocks[0].text.isEmpty, label)
        }
        let b = try parseChapter(variants[0].1, label: "utf16le")
        XCTAssertEqual(b?.chapters.first?.blocks.first?.text, "Zoë – 日本語 — ✓")
    }

    /// Found with Project Gutenberg "Pride and Prejudice" (illustrated): `<td>&nbsp;</td>` spacer cells became blank blocks.
    func testInvisibleOnlyBlocksAreDropped() throws {
        let b = try parseChapter(xhtml("<table><tr><td>&nbsp;</td><td>\u{200B} \u{00A0}</td></tr></table><p>&#160;</p><p>real</p>"), label: "nbsp")
        XCTAssertEqual(b?.chapters.first?.blocks.map(\.text), ["real"])
    }

    func testZipSlipAndBackslashNamesAreInert() throws {
        let url = try zip([("../../evil.xhtml", xhtml("<p>evil</p>")), ("..\\evil2.xhtml", xhtml("<p>evil</p>")),
                           ("/abs.xhtml", xhtml("<p>evil</p>")), ("c1.xhtml", xhtml("<p>fine</p>"))])
        guard case .success(let book)? = run(url) else { return XCTFail() }
        XCTAssertEqual(book.chapters.first?.blocks.first?.text, "fine")
    }
}

final class XPointerFuzzTests: XCTestCase {
    func testRandomAndHostileStringsNeverCrash() throws {
        let book = try EPUBTestSupport.parse("multispine")
        let resolver = XPointerResolver()
        var rng = SplitMix(seed: 42)
        let alphabet = Array("/body DocFragment[]0123456789text().:-_xyzp\u{e9}\u{1F600}\n").map(String.init)
        var inputs = ["", "/", "//", "/body", "/body/DocFragment[0]", "/body/DocFragment[-1]/body",
                      "/body/DocFragment[99999999999999999999999]/body/p", "/body/DocFragment[1]/body/p[99999999999999999999]/text().1",
                      "/body/DocFragment[1]/body/p/text().99999999999999999999", "/body/DocFragment[1]/body/p/text().-5",
                      "/body/DocFragment[1]/body/p[0]/text().0", "/body/DocFragment[1]/body/" + String(repeating: "p/", count: 100_000),
                      String(repeating: "[", count: 100_000), "/body/DocFragment[1]/body/p/text()[2].3", "\0", "/body/DocFragment[1]/body/p/text().0\n"]
        for _ in 0..<3000 {
            inputs.append((0..<Int(rng.next() % 60)).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }.joined())
        }
        for raw in inputs {
            _ = ParsedXPointer.parse(raw)
            for pct in [nil, 0.5, -1, 2, Double.nan, Double.infinity] as [Double?] { _ = resolver.resolve(raw, percentage: pct, in: book) }
        }
        // locate() with out-of-range positions.
        for pos in [BookPosition(chapterIndex: -1, blockIndex: 0), BookPosition(chapterIndex: 0, blockIndex: 10_000),
                    BookPosition(chapterIndex: 0, blockIndex: 0, characterOffset: Int.max), BookPosition(chapterIndex: 0, blockIndex: 0, characterOffset: Int.min)] {
            _ = resolver.locate(pos, in: book)
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
