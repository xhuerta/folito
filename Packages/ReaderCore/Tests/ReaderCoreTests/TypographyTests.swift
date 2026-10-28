import XCTest
@testable import ReaderCore

final class TypographyTests: XCTestCase {
    func testDefaultsReproduceOriginalLook() {
        let t = ReaderTypography.default
        XCTAssertEqual(t.fontSize, 16)
        XCTAssertEqual(t.theme, .dark)
        XCTAssertEqual(t.spec(for: .paragraph).pointSize, 16)
        XCTAssertEqual(t.spec(for: .heading1).pointSize, 21.6)
        XCTAssertEqual(t.spec(for: .heading2).pointSize, 20)
        XCTAssertFalse(t.spec(for: .paragraph).bold)
        XCTAssertTrue(t.spec(for: .heading3).bold)
    }

    func testClamping() {
        let t = ReaderTypography(fontSize: 99, lineSpacing: -3, horizontalMargin: 500, paragraphSpacing: 0,
                                 headingScale: .nan, tracking: .infinity, stamp: -5)
        XCTAssertEqual(t.fontSize, 28)
        XCTAssertEqual(t.lineSpacing, 0)
        XCTAssertEqual(t.horizontalMargin, 16)
        XCTAssertEqual(t.paragraphSpacing, 2)
        XCTAssertEqual(t.headingScale, 1)
        XCTAssertEqual(t.tracking, 0)
        XCTAssertEqual(t.stamp, 0)
    }

    func testEncodeDecodeRoundTrip() throws {
        let t = ReaderTypography(fontFamily: .serif, fontSize: 20, lineSpacing: 3, horizontalMargin: 8,
                                 paragraphSpacing: 12, alignment: .center, boldText: true, headingScale: 1.5,
                                 tracking: -0.5, theme: .sepia, stamp: 1_700_000_000)
        let data = try XCTUnwrap(t.encoded())
        XCTAssertEqual(ReaderTypography.decode(data), t)
        XCTAssertEqual(ReaderTypography.decode(json: try XCTUnwrap(t.jsonString())), t)
    }

    func testDecodeIsTolerant() {
        // Missing fields, unknown enum values, wrong types and out-of-range numbers never fail.
        let json = #"{"fontFamily":"comic-sans","fontSize":500,"theme":"neon","boldText":"yes","future":1}"#
        let t = ReaderTypography.decode(json: json)
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.fontFamily, .system)
        XCTAssertEqual(t?.fontSize, 28)
        XCTAssertEqual(t?.theme, .dark)
        XCTAssertEqual(t?.boldText, false)
        XCTAssertEqual(ReaderTypography.decode(json: "{}"), .default)
        XCTAssertNil(ReaderTypography.decode(json: "not json"))
    }

    func testHeadingScale() {
        var t = ReaderTypography.default
        t.headingScale = 0
        XCTAssertEqual(t.spec(for: .heading1).pointSize, 16)
        t.headingScale = 2
        XCTAssertEqual(t.spec(for: .heading1).pointSize, 27.2)
        XCTAssertEqual(t.spec(for: .paragraph).pointSize, 16)
    }

    func testSpecFlags() {
        var t = ReaderTypography.default
        XCTAssertTrue(t.spec(for: .quote).italic)
        XCTAssertEqual(t.spec(for: .quote).indent, 8)
        XCTAssertTrue(t.spec(for: .listItem).showsBullet)
        XCTAssertFalse(t.spec(for: .paragraph).showsBullet)
        t.boldText = true
        XCTAssertTrue(t.spec(for: .paragraph).bold)
        t.boldText = false
        t.theme = .highContrast
        XCTAssertTrue(t.spec(for: .paragraph).bold)
    }

    func testPresets() {
        for preset in ReaderTypography.Preset.allCases {
            let t = ReaderTypography(fontSize: 18, stamp: 42).applying(preset)
            XCTAssertEqual(t, t.clamped(), "\(preset)")
            XCTAssertEqual(t.stamp, 42, "stamp is preserved")
        }
        XCTAssertEqual(ReaderTypography(fontSize: 18).applying(.standard).fontSize, 18)
        XCTAssertEqual(ReaderTypography().applying(.largePrint).fontSize, 22)
        XCTAssertEqual(ReaderTypography(fontSize: 12).applying(.compact).fontSize, 12)
        XCTAssertEqual(ReaderTypography().applying(.night).theme, .dim)
    }

    func testRenderKeyIgnoresStampOnly() {
        var a = ReaderTypography.default
        var b = a
        b.stamp = 99
        XCTAssertEqual(a.renderKey, b.renderKey)
        XCTAssertTrue(a.sameLook(as: b))
        a.lineSpacing = 2
        XCTAssertNotEqual(a.renderKey, b.renderKey)
    }

    func testThemeContrast() {
        for theme in ReaderTypography.Theme.allCases {
            XCTAssertGreaterThanOrEqual(theme.palette.contrastRatio, 7.0, "\(theme)")
        }
        XCTAssertEqual(ReaderTypography.Theme.highContrast.palette.contrastRatio, 21, accuracy: 0.01)
    }

    // MARK: Store

    private func makeDefaults() -> UserDefaults {
        let name = "typo-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testStoreMigratesLegacyFontSize() {
        let d = makeDefaults()
        d.set(22.0, forKey: TypographyStore.legacyFontSizeKey)
        let store = TypographyStore(defaults: d)
        XCTAssertEqual(store.load().fontSize, 22)
        XCTAssertNil(d.object(forKey: TypographyStore.legacyFontSizeKey))
        XCTAssertEqual(store.load().fontSize, 22, "migrated value persisted")
    }

    func testStoreMigrationClampsLegacyValue() {
        let d = makeDefaults()
        d.set(1000.0, forKey: TypographyStore.legacyFontSizeKey)
        XCTAssertEqual(TypographyStore(defaults: d).load().fontSize, 28)
    }

    func testStoreSaveLoadAndReset() {
        let store = TypographyStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), .default)
        var t = ReaderTypography.default
        t.theme = .sepia; t.stamp = 10
        store.save(t)
        XCTAssertEqual(store.load(), t)
        store.reset(now: 77)
        XCTAssertEqual(store.load().stamp, 77)
        XCTAssertTrue(store.load().sameLook(as: .default))
        store.reset(now: nil)
        XCTAssertEqual(store.load(), .default)
    }

    func testStoreIgnoresCorruptData() {
        let d = makeDefaults()
        d.set(Data("garbage".utf8), forKey: TypographyStore.key)
        XCTAssertEqual(TypographyStore(defaults: d).load(), .default)
    }

    // MARK: Sync

    func testSyncWireRoundTripAndLastWriterWins() throws {
        var remote = ReaderTypography.default
        remote.fontSize = 24; remote.stamp = 100
        let ctx = TypographySync.context(for: remote)
        XCTAssertTrue(ctx[TypographySync.typographyKey] is String)
        XCTAssertEqual(ctx[TypographySync.stampKey] as? Int, 100)
        let decoded = try XCTUnwrap(TypographySync.decode(from: ctx))
        XCTAssertEqual(decoded, remote)

        var local = ReaderTypography.default
        local.stamp = 100
        XCTAssertFalse(TypographySync.shouldApply(incoming: decoded, local: local), "tie keeps local")
        local.stamp = 99
        XCTAssertTrue(TypographySync.shouldApply(incoming: decoded, local: local))
        local.stamp = 101
        XCTAssertFalse(TypographySync.shouldApply(incoming: decoded, local: local))
        XCTAssertNil(TypographySync.decode(from: ["type": "settings"]))
        XCTAssertEqual(TypographySync.nextStamp(now: 500, after: 100), 500)
        XCTAssertEqual(TypographySync.nextStamp(now: 500, after: 500), 501)
        XCTAssertEqual(TypographySync.nextStamp(now: 100, after: 500), 501)
    }
}
