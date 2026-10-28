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

    func testInsecureWarning() {
        XCTAssertNil(SyncSettingsValidator.insecureWarning(server: "https://sync.example.org"))
        XCTAssertNil(SyncSettingsValidator.insecureWarning(server: "sync.example.org"))
        XCTAssertTrue(SyncSettingsValidator.insecureWarning(server: "http://192.168.1.5:8081")?.contains("home network") == true)
        XCTAssertTrue(SyncSettingsValidator.insecureWarning(server: "http://nas.local")?.contains("home network") == true)
        XCTAssertTrue(SyncSettingsValidator.insecureWarning(server: "http://nas")?.contains("home network") == true)
        XCTAssertTrue(SyncSettingsValidator.insecureWarning(server: "http://sync.example.org")?.contains("blocks") == true)
    }

    func testATSErrorMessage() {
        let msg = SyncSettingsValidator.message(for: URLError(.appTransportSecurityRequiresSecureConnection))
        XCTAssertTrue(msg.contains("https"))
    }

    func testSettingsSchemaAndLibraryContext() {
        let info = WatchSchema.settingsInfo(server: "s", user: "u", password: "p", stamp: 7)
        XCTAssertEqual(info["type"] as? String, "settings")
        XCTAssertEqual(info["settingsStamp"] as? Int, 7)
        XCTAssertEqual(WatchSchema.libraryHashes(from: ["type": "library", "hashes": ["a", "b"]]), ["a", "b"])
        XCTAssertNil(WatchSchema.libraryHashes(from: ["type": "settings"]))
    }

    @MainActor
    func testReconcileMarksUnsentWhenWatchLacksBook() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootDirectory: dir)
        XCTAssertTrue(store.unsentBooks.isEmpty)
        store.reconcile(watchHashes: [], inFlight: [])
        XCTAssertTrue(store.entries.isEmpty)
    }
}
