import XCTest
import Foundation
@testable import ReaderCore

/// Runs the real parser over every `*.epub` in `FOLITO_EPUB_DIR` (e.g. Project Gutenberg downloads kept
/// OUTSIDE the repo) and checks structural invariants. If `FOLITO_REPORT_DIR` is set, writes
/// `<name>.book.json` (the ProcessedBook the watch would receive) and `report.tsv` there.
/// `FOLITO_SKIP_INVARIANTS=1` only parses + encodes (for timing / memory runs; the invariant pass is slow in debug).
final class RealWorldBooksTests: XCTestCase {
    func testEveryBookInDirectory() throws {
        guard let dir = ProcessInfo.processInfo.environment["FOLITO_EPUB_DIR"] else {
            throw XCTSkip("FOLITO_EPUB_DIR not set")
        }
        let reportDir = ProcessInfo.processInfo.environment["FOLITO_REPORT_DIR"].map { URL(fileURLWithPath: $0) }
        if let reportDir { try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true) }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".epub") }.sorted()
        XCTAssertFalse(files.isEmpty)
        var report = "name\tepubKB\tparseSec\tchapters\tblocks\tchars\tjsonKB\thash\ttitle\ttocSource\ttocEntries\ttocMaxDepth\ttocUnresolved\ttocOutOfOrder\ttocChapterLevel\n"
        for f in files {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let t0 = Date()
            let book = try EPUBParser().process(epubAt: url)
            let secs = Date().timeIntervalSince(t0)
            if ProcessInfo.processInfo.environment["FOLITO_SKIP_INVARIANTS"] == nil {
                try Self.checkInvariants(book, name: f)
                Self.checkTOC(book, name: f)
            }
            let enc = JSONEncoder()
            let json = try enc.encode(book)
            let decoded = try JSONDecoder().decode(ProcessedBook.self, from: json)
            XCTAssertEqual(decoded, book, f)
            if let reportDir { try json.write(to: reportDir.appendingPathComponent(f + ".book.json")) }
            let nBlocks = book.chapters.reduce(0) { $0 + $1.blocks.count }
            report += "\(f)\t\(size / 1024)\t\(String(format: "%.2f", secs))\t\(book.chapters.count)\t\(nBlocks)\t\(book.totalCharacters)\t\(json.count / 1024)\t\(book.documentHash)\t\(book.metadata.title)\t\(Self.tocColumns(book))\n"
            print("REAL \(f): \(size / 1024)KB parse=\(String(format: "%.2f", secs))s chapters=\(book.chapters.count) blocks=\(nBlocks) chars=\(book.totalCharacters) json=\(json.count / 1024)KB")
        }
        if let reportDir { try report.write(to: reportDir.appendingPathComponent("report.tsv"), atomically: true, encoding: .utf8) }
    }

    /// tocSource, entries, max depth, unresolved entries, out-of-order entries, chapter level (0-based).
    static func tocColumns(_ book: ProcessedBook) -> String {
        guard let toc = book.toc, let index = TOCIndex(book: book) else { return "-\t0\t0\t0\t0\t-" }
        let unresolved = toc.filter { $0.position == nil }.count
        let outOfOrder = toc.indices.filter { toc[$0].position != nil && !index.isOrdered[$0] }.count
        return "\(book.tocSource?.rawValue ?? "-")\t\(toc.count)\t\((toc.map(\.depth).max() ?? 0) + 1)\t\(unresolved)\t\(outOfOrder)\t\(index.chapterLevel)"
    }

    /// Known TOC shapes of the books `scripts/check_real_books.sh` downloads (Project Gutenberg splits big
    /// HTML files by size, so most entries are `#fragment`s into a few spine items): a minimum entry count,
    /// and a label whose resolved block must contain that text.
    static let tocExpectations: [String: (minEntries: Int, probe: String?)] = [
        "moby.epub": (135, "Loomings"),
        "pride.epub": (61, nil),
        "lesmis.epub": (380, nil),
        "alice.epub": (12, "Rabbit-Hole"),
    ]

    static func checkTOC(_ book: ProcessedBook, name: String, file: StaticString = #filePath, line: UInt = #line) {
        func fail(_ m: String) { XCTFail("\(name): \(m)", file: file, line: line) }
        guard let toc = book.toc, let index = TOCIndex(book: book) else {
            if tocExpectations[name] != nil { fail("no TOC") }
            return
        }
        for (i, e) in toc.enumerated() {
            if i > 0, e.depth > toc[i - 1].depth + 1 { fail("TOC depth jumps at \(i)") }
            guard let p = e.position else { continue }
            if !book.chapters.indices.contains(p.chapterIndex) || !book.chapters[p.chapterIndex].blocks.indices.contains(p.blockIndex)
                || p.characterOffset > book.chapters[p.chapterIndex].blocks[p.blockIndex].text.count {
                fail("TOC entry \(i) out of range: \(p)")
            }
        }
        let resolved = toc.filter { $0.position != nil }.count
        let ordered = index.isOrdered.filter { $0 }.count
        if Double(ordered) < 0.95 * Double(resolved) { fail("only \(ordered)/\(resolved) TOC entries in order") }
        guard let expected = tocExpectations[name] else { return }
        if toc.count < expected.minEntries { fail("TOC has \(toc.count) entries, expected >= \(expected.minEntries)") }
        // Fragments resolve into the files: far more distinct positions than spine chapters.
        let distinct = Set(toc.compactMap { $0.position.map { "\($0.chapterIndex):\($0.blockIndex)" } }).count
        if Double(distinct) < 0.8 * Double(toc.count) { fail("only \(distinct) distinct TOC positions for \(toc.count) entries") }
        if let probe = expected.probe {
            guard let entry = toc.first(where: { $0.title.localizedCaseInsensitiveContains(probe) }), let p = entry.position else {
                fail("no resolved TOC entry for \(probe)"); return
            }
            let text = book.chapters[p.chapterIndex].blocks[p.blockIndex].text
            if !text.localizedCaseInsensitiveContains(probe) { fail("TOC \(probe) resolves to \"\(text.prefix(60))\"") }
        }
    }

    static func checkInvariants(_ book: ProcessedBook, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        func fail(_ m: String) { XCTFail("\(name): \(m)", file: file, line: line) }
        if book.chapters.isEmpty { fail("no chapters"); return }
        if book.totalCharacters < 1000 { fail("tiny book \(book.totalCharacters)") }
        XCTAssertEqual(book.documentHash.count, 32, file: file, line: line)

        // globalOffset contiguity, spine ordering, nonblank text
        var expected = 0, prevSpine = 0
        for ch in book.chapters {
            if ch.spineIndex <= prevSpine { fail("spineIndex not increasing at \(ch.spineIndex)") }
            prevSpine = ch.spineIndex
            for b in ch.blocks {
                if b.globalOffset != expected { fail("offset gap in spine \(ch.spineIndex)"); return }
                expected += b.text.count
                if b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail("blank block in spine \(ch.spineIndex)") }
                if b.text.contains("\u{FFFD}") { fail("U+FFFD in text, spine \(ch.spineIndex)") }
                if b.text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }) { fail("control char in text") }
                for s in b.spans where s.location < 0 || s.length <= 0 || s.location + s.length > b.text.utf16.count {
                    fail("span out of range in spine \(ch.spineIndex)")
                }
            }
        }
        XCTAssertEqual(expected, book.totalCharacters, file: file, line: line)

        // Every block xpointer resolves back to itself; locate() round trip; percentage monotonic.
        let resolver = XPointerResolver()
        var lastPct = -1.0
        var seen = Set<String>()
        for (ci, ch) in book.chapters.enumerated() {
            for (bi, b) in ch.blocks.enumerated() {
                if !seen.insert(b.xpointer).inserted { fail("duplicate xpointer \(b.xpointer)") }
                guard let parsed = ParsedXPointer.parse(b.xpointer) else { fail("unparsable \(b.xpointer)"); continue }
                XCTAssertEqual(parsed.spineIndex, ch.spineIndex, file: file, line: line)
                guard case .position(let pos, let trimmed)? = resolver.resolve(b.xpointer, percentage: nil, in: book) else {
                    fail("unresolved \(b.xpointer)"); continue
                }
                if pos.chapterIndex != ci || pos.blockIndex != bi || trimmed != 0 {
                    fail("resolve mismatch \(b.xpointer) -> \(pos) trimmed \(trimmed)")
                }
                // mid-block position
                let off = b.text.count / 2
                guard let (xp, pct) = resolver.locate(BookPosition(chapterIndex: ci, blockIndex: bi, characterOffset: off), in: book) else {
                    fail("locate nil"); continue
                }
                if pct < lastPct { fail("percentage not monotonic at \(b.xpointer)") }
                lastPct = pct
                if case .position(let back, _)? = resolver.resolve(xp, percentage: pct, in: book) {
                    if back != BookPosition(chapterIndex: ci, blockIndex: bi, characterOffset: off) {
                        fail("locate round trip \(xp): \(back) != \(ci),\(bi),\(off)")
                    }
                } else { fail("locate result unresolved \(xp)") }
            }
        }
        XCTAssertLessThanOrEqual(lastPct, 1.0, file: file, line: line)
    }
}
