import XCTest
import ReaderCore
@testable import Folito

final class DictionaryPhoneTests: XCTestCase {
    func testDictionarySchema() {
        let m = WatchSchema.dictionaryMetadata(id: "readerdict-en", sha256: "abc", size: 42)
        XCTAssertEqual(m["type"] as? String, "dictionary")
        XCTAssertEqual(m["dictionaryId"] as? String, "readerdict-en")
        XCTAssertEqual(m["sha256"] as? String, "abc")
        XCTAssertEqual(m["size"] as? Int64, 42)
        let d = WatchSchema.deleteDictionary(id: "readerdict-en")
        XCTAssertEqual(d["type"] as? String, "delete_dictionary")
        XCTAssertEqual(d["dictionaryId"] as? String, "readerdict-en")
        XCTAssertEqual(WatchSchema.libraryDictionaries(from: ["type": "library", "hashes": [], "dictionaries": ["a"]]), ["a"])
        XCTAssertNil(WatchSchema.libraryDictionaries(from: ["type": "library", "hashes": []]), "older watch app")
        XCTAssertNil(WatchSchema.libraryDictionaries(from: ["type": "settings", "dictionaries": ["a"]]))
    }

    func testWatchState() {
        XCTAssertEqual(DictionaryWatchState(id: "a", installed: false, onWatch: ["a"], sending: []), .notInstalled)
        XCTAssertEqual(DictionaryWatchState(id: "a", installed: true, onWatch: ["a"], sending: ["a"]), .onWatch)
        XCTAssertEqual(DictionaryWatchState(id: "a", installed: true, onWatch: [], sending: ["a"]), .sending)
        XCTAssertEqual(DictionaryWatchState(id: "a", installed: true, onWatch: nil, sending: []), .waiting)
        XCTAssertNil(DictionaryWatchState.notInstalled.text)
        let texts = [DictionaryWatchState.onWatch, .sending, .waiting].compactMap(\.text)
        XCTAssertEqual(Set(texts).count, 3)
    }

    func testSizesText() {
        let text = DictionarySizes.text(download: 48_779_057, installed: 70_000_000, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(text.hasPrefix("Download 48"), text)
        XCTAssertTrue(text.contains("On watch 70"), text)
    }

    func testErrorMessages() {
        let offline = UserFacingError.dictionaryFailed(language: "French", error: URLError(.notConnectedToInternet))
        let http = UserFacingError.dictionaryFailed(language: "French", error: FileDownload.Failure.http(503))
        let damaged = UserFacingError.dictionaryFailed(language: "French", error: DictionaryImportError.checksumMismatch)
        let format = UserFacingError.dictionaryFailed(language: "French", error: DictionaryImportError.notAStarDict)
        let full = UserFacingError.dictionaryFailed(language: "French", error: CocoaError(.fileWriteOutOfSpace))
        XCTAssertEqual(offline, http)
        let all = [offline, damaged, format, full]
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
        for e in [offline, damaged, format] { XCTAssertTrue(e.message.contains("French"), e.message) }
        XCTAssertTrue(full.message.contains("storage"))
    }

    func testDownloadVerification() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: 10).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let d = DictionaryCatalog.all[0]
        XCTAssertNoThrow(try DictionaryManager.verify(download: file, response: .init(status: 200, expectedLength: 10), descriptor: d))
        XCTAssertNoThrow(try DictionaryManager.verify(download: file, response: .init(status: 200, expectedLength: -1), descriptor: d))
        XCTAssertThrowsError(try DictionaryManager.verify(download: file, response: .init(status: 200, expectedLength: 11), descriptor: d))
        XCTAssertThrowsError(try DictionaryManager.verify(download: file, response: .init(status: 404, expectedLength: 10), descriptor: d))
        var pinned = d
        pinned.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try DictionaryManager.verify(download: file, response: .init(status: 200, expectedLength: 10), descriptor: pinned))
    }

    @MainActor
    func testManagerStartsEmptyAndDeletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DictionaryPhoneTests"))
        defaults.removePersistentDomain(forName: "DictionaryPhoneTests")
        let manager = DictionaryManager(rootDirectory: root, defaults: defaults)
        XCTAssertTrue(manager.installedInfos.isEmpty)
        XCTAssertTrue(manager.transferList().isEmpty)
        var deleted: [String] = []
        manager.onDeleted = { deleted.append($0) }
        manager.delete("readerdict-en")
        XCTAssertEqual(deleted, ["readerdict-en"])
        XCTAssertEqual(DictionaryManager.languageName("fr", locale: Locale(identifier: "en_US")), "French")
    }
}
