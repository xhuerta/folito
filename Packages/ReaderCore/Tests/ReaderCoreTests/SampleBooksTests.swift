import XCTest
@testable import ReaderCore

/// The sample books bundled in the iPhone app (iOSApp/Resources/SampleBooks, built by
/// scripts/samples/build_samples.py from docs/samples-src; see docs/SAMPLE_BOOKS.md) must parse with the app's
/// own EPUB parser, carry the right language and title, and pass the same invariants as real-world books.
/// Read from the repository checkout, so this runs on Linux too.
final class SampleBooksTests: XCTestCase {
    /// Keep in sync with LANGUAGES in scripts/samples/build_samples.py and `SampleBooks` in the iPhone app.
    static let expected: [(language: String, title: String, author: String)] = [
        ("en", "Pride and Prejudice", "Jane Austen"),
        ("es", "Don Quijote de la Mancha", "Miguel de Cervantes Saavedra"),
        ("fr", "Les Misérables", "Victor Hugo"),
        ("de", "Die Verwandlung", "Franz Kafka"),
        ("it", "I promessi sposi", "Alessandro Manzoni"),
        ("pt-BR", "Dom Casmurro", "Machado de Assis"),
        ("ja", "吾輩は猫である", "夏目漱石"),
        ("zh-Hans", "狂人日记", "鲁迅"),
    ]

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ReaderCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ReaderCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("iOSApp/Resources/SampleBooks", isDirectory: true)
    }

    func testEveryLanguageHasExactlyOneSample() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { $0.hasSuffix(".epub") }.sorted()
        XCTAssertEqual(files, Self.expected.map { "sample-\($0.language).epub" }.sorted())
    }

    func testSamplesParseWithLanguageAndTitle() throws {
        var hashes = Set<String>()
        for sample in Self.expected {
            let url = Self.directory.appendingPathComponent("sample-\(sample.language).epub")
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertLessThan(size, 250_000, "\(sample.language): keep the sample small")

            let book = try EPUBParser().process(epubAt: url)
            XCTAssertEqual(book.metadata.language, sample.language)
            XCTAssertEqual(book.metadata.title, sample.title)
            XCTAssertEqual(book.metadata.authors, [sample.author])
            XCTAssertTrue(hashes.insert(book.documentHash).inserted, "\(sample.language): duplicate document hash")

            // At least one text chapter plus the closing "about this sample" chapter, each titled from the nav.
            XCTAssertGreaterThanOrEqual(book.chapters.count, 2, sample.language)
            XCTAssertTrue(book.chapters.allSatisfy { !($0.title ?? "").isEmpty }, "\(sample.language): untitled chapter")
            XCTAssertGreaterThan(book.totalCharacters, 4_000, sample.language)
            // No Project Gutenberg boilerplate may remain in the text.
            let text = book.chapters.flatMap(\.blocks).map(\.text).joined(separator: "\n")
            XCTAssertFalse(text.contains("*** START OF"), sample.language)
            XCTAssertFalse(text.contains("Project Gutenberg License"), sample.language)
            XCTAssertFalse(text.contains("[Illustration"), sample.language)

            try RealWorldBooksTests.checkInvariants(book, name: url.lastPathComponent)

            // The book survives the encoding the iPhone sends to the watch.
            let decoded = try JSONDecoder().decode(ProcessedBook.self, from: JSONEncoder().encode(book))
            XCTAssertEqual(decoded, book, sample.language)
        }
    }
}
