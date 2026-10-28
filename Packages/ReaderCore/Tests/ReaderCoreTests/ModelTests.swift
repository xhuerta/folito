import XCTest
@testable import ReaderCore

final class ModelTests: XCTestCase {
    func testProcessedBookRoundTrip() throws {
        let block = Block(text: "Hello", xpointer: "/body/DocFragment[1]/body/p[1]/text().0", globalOffset: 0)
        let book = ProcessedBook(
            metadata: BookMetadata(title: "T", authors: ["A"]),
            documentHash: "abc", metaHash: "def",
            chapters: [Chapter(spineIndex: 1, title: nil, blocks: [block])], totalCharacters: 5)
        let data = try JSONEncoder().encode(book)
        XCTAssertEqual(try JSONDecoder().decode(ProcessedBook.self, from: data), book)
    }
}
