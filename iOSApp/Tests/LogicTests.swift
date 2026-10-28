import XCTest
@testable import WristReader

final class LogicTests: XCTestCase {
    func testCredentialsDefaultsAndNormalises() {
        let c = SyncSettingsValidator.credentials(server: "", user: " bob ", password: "pw")
        XCTAssertEqual(c?.serverURL.absoluteString, "https://sync.koreader.rocks")
        XCTAssertEqual(c?.username, "bob")
        XCTAssertEqual(SyncSettingsValidator.credentials(server: "example.com/", user: "a", password: "b")?.serverURL.absoluteString,
                       "https://example.com")
    }

    func testCredentialsRejectMissingFields() {
        XCTAssertNil(SyncSettingsValidator.credentials(server: "", user: "", password: "x"))
        XCTAssertNil(SyncSettingsValidator.credentials(server: "", user: "a", password: ""))
        XCTAssertNil(SyncSettingsValidator.credentials(server: "ftp://x", user: "a", password: "b"))
    }

    func testBookDisplay() {
        XCTAssertEqual(BookDisplay.author(from: []), "Unknown author")
        XCTAssertEqual(BookDisplay.author(from: ["A", " B "]), "A, B")
        XCTAssertEqual(BookDisplay.title("  ", fallbackFileName: "x.epub"), "x")
    }

    func testSchema() {
        let e = LibraryEntry(documentHash: "h", title: "T", author: "A", fileName: "h.wrbook", size: 5,
                             importedAt: Date(), sentToWatch: false)
        let m = WatchSchema.bookMetadata(for: e, formatVersion: 1)
        XCTAssertEqual(m["documentHash"] as? String, "h")
        XCTAssertEqual(m["size"] as? Int, 5)
        XCTAssertEqual(WatchSchema.deleteBook(hash: "h")["type"] as? String, "delete_book")
    }
}
