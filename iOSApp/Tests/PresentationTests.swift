import XCTest
import ReaderCore
@testable import Folito

/// Pure presentation logic: error wording, formatting, watch state, About data.
final class PresentationTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    // MARK: Import errors

    func testDamagedEPUBGetsSpecificActionableMessage() {
        for error in [EPUBError.invalidArchive, .missingContainer, .missingPackageDocument, .malformedXML("x")] {
            let e = UserFacingError.importFailed(fileName: "Moby.epub", error: error)
            XCTAssertEqual(e.title, "Couldn’t Import Book")
            XCTAssertTrue(e.message.contains("Moby.epub"), e.message)
            XCTAssertTrue(e.message.contains("isn’t a valid EPUB"), e.message)
        }
    }

    func testEachImportFailureHasItsOwnMessage() {
        let messages = [EPUBError.emptySpine, .missingResource("a.xhtml"), .archiveTooLarge, .invalidArchive]
            .map { UserFacingError.importFailed(fileName: "b.epub", error: $0).message }
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertEqual(UserFacingError.importFailed(fileName: "b.epub", error: EPUBError.entryTooLarge("x")).message,
                       UserFacingError.importFailed(fileName: "b.epub", error: EPUBError.archiveTooLarge).message)
    }

    func testDiskFullAndUnknownImportErrors() {
        let full = UserFacingError.importFailed(fileName: "b.epub", error: CocoaError(.fileWriteOutOfSpace))
        XCTAssertTrue(full.message.contains("storage"), full.message)
        let other = UserFacingError.importFailed(fileName: "b.epub", error: URLError(.unknown))
        XCTAssertTrue(other.message.contains("b.epub"), other.message)
        XCTAssertFalse(other.title.isEmpty)
        XCTAssertNotEqual(other.title, "Error")
    }

    func testUnreadableFileMentionsFileAndRemedy() {
        let e = UserFacingError.fileUnreadable(fileName: "Book.epub")
        XCTAssertEqual(e.title, "Couldn’t Open File")
        XCTAssertTrue(e.message.contains("Book.epub"))
        XCTAssertTrue(e.message.contains("Files app"))
    }

    // MARK: Sync errors

    func testSyncMessages() {
        XCTAssertTrue(UserFacingError.syncMessage(for: KOSyncError.unauthorized).contains("username and password"))
        XCTAssertTrue(UserFacingError.syncMessage(for: KOSyncError.server(status: 503)).contains("503"))
        XCTAssertTrue(UserFacingError.syncMessage(for: URLError(.notConnectedToInternet)).contains("offline"))
        XCTAssertTrue(UserFacingError.syncMessage(for: URLError(.cannotFindHost)).contains("server URL"))
        XCTAssertTrue(UserFacingError.syncMessage(for: URLError(.appTransportSecurityRequiresSecureConnection)).contains("https://"))
        // Never a raw system description.
        XCTAssertFalse(UserFacingError.syncMessage(for: CocoaError(.fileNoSuchFile)).isEmpty)
        XCTAssertEqual(SyncSettingsValidator.message(for: KOSyncError.offline),
                       UserFacingError.syncMessage(for: KOSyncError.offline))
    }

    @MainActor
    func testMissingFieldsStatusIsAFailure() async {
        let s = SyncSettings(keychain: KeychainStore(service: "test.\(UUID().uuidString)"),
                             defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                             clientFactory: { _ in MockKOSyncClient() })
        s.testConnection()
        XCTAssertEqual(s.status?.kind, .failure)
        s.selectedConnectorID = KOSyncConnectorFactory.id
        await s.save()
        XCTAssertEqual(s.status, .missingFields)
    }

    func testReadestMessages() {
        XCTAssertTrue(UserFacingError.syncMessage(for: ReadestError.invalidCredentials).contains("email and password"))
        XCTAssertTrue(UserFacingError.syncMessage(for: ReadestError.unauthorized).contains("Sign in again"))
        XCTAssertTrue(UserFacingError.syncMessage(for: ReadestError.server(status: 502, message: nil)).contains("502"))
    }

    // MARK: Formatting

    func testFormatting() {
        XCTAssertEqual(DisplayFormat.points(18, locale: enUS), "18 pt")
        XCTAssertEqual(DisplayFormat.points(17.6, locale: enUS), "18 pt")
        XCTAssertEqual(DisplayFormat.percent(1.25, locale: enUS), "125%")
        XCTAssertEqual(DisplayFormat.percent(0, locale: enUS), "0%")
        XCTAssertEqual(DisplayFormat.signedPoints(0.25, locale: enUS), "+0.25 pt")
        XCTAssertEqual(DisplayFormat.signedPoints(-1, locale: enUS), "-1.00 pt")
        XCTAssertFalse(DisplayFormat.fileSize(1_500_000, locale: enUS).isEmpty)
        XCTAssertTrue(DisplayFormat.fileSize(1_500_000, locale: enUS).contains("MB"))
    }

    func testFormattingFollowsLocale() {
        XCTAssertEqual(DisplayFormat.signedPoints(0.25, locale: Locale(identifier: "es_ES")).contains("0,25"), true)
    }

    func testReadingSettingsNamesAreComplete() {
        for f in ReaderTypography.FontFamily.allCases { XCTAssertFalse(ReadingSettingsText.name(f).isEmpty) }
        for t in ReaderTypography.Theme.allCases { XCTAssertFalse(ReadingSettingsText.name(t).isEmpty) }
        for p in ReaderTypography.Preset.allCases { XCTAssertFalse(ReadingSettingsText.name(p).isEmpty) }
        for a in ReaderTypography.Alignment.allCases { XCTAssertFalse(ReadingSettingsText.name(a).isEmpty) }
        var t = ReaderTypography.default
        t.fontFamily = .serif; t.fontSize = 18; t.theme = .sepia
        XCTAssertEqual(ReadingSettingsText.previewSummary(t, locale: enUS), "Serif, 18 pt, Sepia")
    }

    // MARK: Watch state

    func testWatchStatusMapping() {
        XCTAssertEqual(WatchStatus(supported: false, activation: .activated, paired: true, appInstalled: true, reachable: true), .unsupported)
        XCTAssertEqual(WatchStatus(supported: true, activation: .notActivated, paired: false, appInstalled: false, reachable: false), .activating)
        XCTAssertEqual(WatchStatus(supported: true, activation: .activated, paired: false, appInstalled: true, reachable: false), .notPaired)
        XCTAssertEqual(WatchStatus(supported: true, activation: .activated, paired: true, appInstalled: false, reachable: false), .appNotInstalled)
        XCTAssertEqual(WatchStatus(supported: true, activation: .activated, paired: true, appInstalled: true, reachable: false), .ready(reachable: false))
        XCTAssertTrue(WatchStatus.ready(reachable: false).canSend)
        XCTAssertFalse(WatchStatus.appNotInstalled.canSend)
    }

    func testBookWatchState() {
        XCTAssertEqual(BookWatchState(sentToWatch: true, inFlight: true), .sending)
        XCTAssertEqual(BookWatchState(sentToWatch: true, inFlight: false), .onWatch)
        XCTAssertEqual(BookWatchState(sentToWatch: false, inFlight: false), .waiting)
        XCTAssertEqual(Set([BookWatchState.onWatch, .sending, .waiting].map(\.text)).count, 3)
    }

    // MARK: About

    func testVersionString() {
        XCTAssertEqual(AppVersion.displayString(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"]), "1.2 (34)")
        XCTAssertEqual(AppVersion.displayString(info: ["CFBundleShortVersionString": "1.2"]), "1.2")
        XCTAssertEqual(AppVersion.displayString(info: ["CFBundleVersion": "34"]), "34")
        XCTAssertFalse(AppVersion.displayString(info: nil).isEmpty)
    }

    func testLinksAreHTTPS() {
        XCTAssertEqual(AppLinks.privacyPolicy.scheme, "https")
        XCTAssertEqual(AppLinks.support.scheme, "https")
    }

    func testLinksPointAtTheSupportSiteInTheReadersLanguage() {
        let base = "https://folito.app/"
        XCTAssertEqual(AppLinks.page("privacy.html", languageCode: "en-US").absoluteString, base + "privacy.html")
        XCTAssertEqual(AppLinks.page("privacy.html", languageCode: "es-MX").absoluteString, base + "es/privacy.html")
        XCTAssertEqual(AppLinks.page("support.html", languageCode: nil).absoluteString, base + "support.html")

        // One case per published language (scripts/site/build.py), plus regional variants and fallbacks.
        let expected: [String: String] = [
            "en": "", "en-GB": "", "es": "es/", "es-419": "es/", "fr-CA": "fr/", "de-AT": "de/", "it": "it/",
            "pt-BR": "pt-br/", "pt-PT": "pt-br/", "ja-JP": "ja/", "zh-Hans": "zh-hans/", "zh-Hans-CN": "zh-hans/",
            "zh-CN": "zh-hans/", "zh": "zh-hans/", "zh-Hant-TW": "", "zh-TW": "", "zh-HK": "",
            "nl-NL": "", "ko": "", "": "",
        ]
        for (code, folder) in expected {
            XCTAssertEqual(AppLinks.page("privacy.html", languageCode: code).absoluteString,
                           base + folder + "privacy.html", "language \(code)")
            XCTAssertEqual(AppLinks.page("support.html", languageCode: code).absoluteString,
                           base + folder + "support.html", "language \(code)")
        }
    }

    func testEveryAcknowledgedComponentShipsItsLicenceText() throws {
        XCTAssertEqual(Set(OpenSourceComponent.all.map(\.name)), ["ZIPFoundation", "Swift Crypto", "SwiftASN1"])
        // The unit tests run hosted in the app, so Bundle.main is the app bundle.
        for c in OpenSourceComponent.all {
            let text = try XCTUnwrap(c.licenseText(), "missing \(c.resource).txt in the app bundle")
            switch c.license {
            case "MIT": XCTAssertTrue(text.contains("MIT License"))
            case "Apache-2.0": XCTAssertTrue(text.contains("Apache License") && text.contains("Version 2.0"))
            default: XCTFail("unexpected licence \(c.license)")
            }
        }
    }

    #if DEBUG
    func testUITestingSampleBookIsConsistent() throws {
        let book = UITesting.sampleBook
        XCTAssertEqual(book.chapters.flatMap(\.blocks).map(\.text.count).reduce(0, +), book.totalCharacters)
        XCTAssertEqual(try BookCodec.decode(BookCodec.encode(book)), book)
    }
    #endif
}
