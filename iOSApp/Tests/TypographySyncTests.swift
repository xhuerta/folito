import XCTest
import ReaderCore
@testable import Folito

final class TypographySyncTests: XCTestCase {
    func testSettingsContextOmitsEmptyAndDefaultStamp() {
        XCTAssertNil(TypographySync.decode(from: WatchSchema.settingsContext(typography: nil)))
        XCTAssertNil(TypographySync.decode(from: WatchSchema.settingsContext(typography: .default)), "stamp 0 = never changed")
    }

    func testTypographyOnlyContext() throws {
        var t = ReaderTypography.default
        t.fontSize = 22; t.stamp = 9
        let info = WatchSchema.settingsContext(typography: t)
        XCTAssertEqual(info["type"] as? String, "settings")
        XCTAssertNil(info["sync_cleared"])
        XCTAssertEqual(TypographySync.decode(from: info), t)
    }

    func testCombinedContextKeepsBoth() throws {
        var t = ReaderTypography.default
        t.theme = .sepia; t.stamp = 3
        let info = WatchSchema.settingsContext(clearedStamp: 7, typography: t)
        XCTAssertEqual(info["sync_cleared"] as? Bool, true)
        XCTAssertEqual(info["settingsStamp"] as? Int, 7)
        XCTAssertEqual(TypographySync.decode(from: info)?.theme, .sepia)
        XCTAssertNil(WatchSchema.settingsContext(clearedStamp: 7, typography: nil)["typography"])
    }

    func testWatchLibraryContextWithTypographyStillParsesAsLibrary() {
        var t = ReaderTypography.default; t.stamp = 5
        var ctx: [String: Any] = ["type": "library", "hashes": ["a"]]
        ctx.merge(TypographySync.context(for: t)) { _, n in n }
        XCTAssertEqual(WatchSchema.libraryHashes(from: ctx), ["a"])
        XCTAssertEqual(TypographySync.decode(from: ctx)?.stamp, 5)
    }
}
