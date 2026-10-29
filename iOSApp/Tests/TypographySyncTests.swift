import XCTest
import ReaderCore
@testable import Folito

final class TypographySyncTests: XCTestCase {
    func testSettingsContextOmitsEmptyAndDefaultStamp() {
        XCTAssertNil(WatchSchema.settingsContext(kosync: nil, typography: nil))
        XCTAssertNil(WatchSchema.settingsContext(kosync: nil, typography: .default), "stamp 0 = never changed")
    }

    func testTypographyOnlyContext() throws {
        var t = ReaderTypography.default
        t.fontSize = 22; t.stamp = 9
        let info = try XCTUnwrap(WatchSchema.settingsContext(kosync: nil, typography: t))
        XCTAssertEqual(info["type"] as? String, "settings")
        XCTAssertNil(info["kosync_server"])
        XCTAssertEqual(TypographySync.decode(from: info), t)
    }

    func testCombinedContextKeepsBoth() throws {
        var t = ReaderTypography.default
        t.theme = .sepia; t.stamp = 3
        let info = try XCTUnwrap(WatchSchema.settingsContext(
            kosync: (server: "https://s", user: "u", password: "p", stamp: 7), typography: t))
        XCTAssertEqual(info["kosync_user"] as? String, "u")
        XCTAssertEqual(info["settingsStamp"] as? Int, 7)
        XCTAssertEqual(TypographySync.decode(from: info)?.theme, .sepia)
        let kosyncOnly = WatchSchema.settingsContext(kosync: (server: "s", user: "u", password: "p", stamp: 1), typography: nil)
        XCTAssertNil(kosyncOnly?["typography"])
    }

    func testWatchLibraryContextWithTypographyStillParsesAsLibrary() {
        var t = ReaderTypography.default; t.stamp = 5
        var ctx: [String: Any] = ["type": "library", "hashes": ["a"]]
        ctx.merge(TypographySync.context(for: t)) { _, n in n }
        XCTAssertEqual(WatchSchema.libraryHashes(from: ctx), ["a"])
        XCTAssertEqual(TypographySync.decode(from: ctx)?.stamp, 5)
    }
}
