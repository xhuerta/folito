import UIKit
import XCTest

/// The iPhone screenshots of the App Store listing (docs/appstore/SCREENSHOTS.md), in one language
/// (`SCREENSHOT_LANG`, seeded from `AppStoreSeeds/<lang>.json` through `UITESTING_APPSTORE_SEED`): the Library
/// with the language's sample book on top, the sample book's details with the progress synced from the watch,
/// and the Reading tab with its live preview. Elements are found by identifier or position, never by English
/// labels, and every navigation title on a captured screen must fit (no truncated titles). Launched with `-UITestingSeedCovers` (Debug builds only:
/// public-domain books with generated covers), built from the full texts in `AppStoreBooks` (so the Library shows
/// real book sizes), and `-UITestingSimulateWatch`, which shows the Library as with a paired, reachable Apple Watch
/// that already has the books (nothing is sent; Release builds ignore both). The whole screen is captured,
/// status bar included; macos.yml runs this suite on one simulator per required App Store display size, with the
/// status bar overridden (9:41, full battery, no carrier name), and exports the attachments as the
/// `app-store-screenshots` artifact.
final class AppStoreScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits up to `timeout` seconds for `element`; on a timeout fails the test with `message`, a screenshot
    /// (attachment "failure screen") and the accessibility tree. The timeouts are generous: on a busy CI runner
    /// the first launch on a just-booted simulator has taken over a minute.
    @MainActor
    private func require(_ element: XCUIElement, _ timeout: TimeInterval, _ message: String,
                         in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "failure screen"
        shot.lifetime = .keepAlways
        XCTContext.runActivity(named: message) { $0.add(shot) }
        XCTFail("\(message) (waited \(Int(timeout)) s). Tree:\n\(app.debugDescription)", file: file, line: line)
    }

    /// The language of the set: `SCREENSHOT_LANG` in the test runner's environment (xcodebuild passes
    /// `TEST_RUNNER_SCREENSHOT_LANG`), `en` by default.
    private static var language: String {
        ProcessInfo.processInfo.environment["SCREENSHOT_LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en"
    }

    /// Fails when a navigation title on screen is cut: its text, measured in a font no larger than the title's,
    /// is wider than its element (UIKit shortens a title that does not fit with an ellipsis).
    @MainActor
    private func assertTitlesFit(_ screen: String, in app: XCUIApplication) {
        for title in app.navigationBars.staticTexts.allElementsBoundByIndex where title.exists && !title.label.isEmpty {
            let frame = title.frame
            guard frame.width > 0 else { continue }
            // Inline titles are 17 pt semibold, large titles 34 pt bold: measure a little smaller than either.
            let font = UIFont.systemFont(ofSize: frame.height > 30 ? 30 : 15, weight: .regular)
            let needed = (title.label as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(needed, frame.width + 1,
                                     "\(screen) [\(Self.language)]: the title \u{201C}\(title.label)\u{201D} is cut (element \(frame))")
        }
    }

    @MainActor
    func testAppStoreScreenshots() throws {
        let lang = Self.language
        let seedURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AppStoreSeeds", withExtension: nil),
                                    "AppStoreSeeds missing from the UI test bundle").appendingPathComponent("\(lang).json")
        let seed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: seedURL)) as? [String: Any])
        let appleLanguage = try XCTUnwrap(seed["appleLanguage"] as? String)
        let appleLocale = try XCTUnwrap(seed["appleLocale"] as? String)
        let library = try XCTUnwrap(seed["library"] as? [[String: Any]])
        let sample = try XCTUnwrap(seed["sample"] as? [String: Any])
        let sampleTitle = try XCTUnwrap(sample["title"] as? String)

        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedCovers", "-UITestingSimulateWatch", "-UITestingSkipOnboarding",
                                "-AppleLanguages", "(\"\(appleLanguage)\")", "-AppleLocale", appleLocale]
        // The simulator app reads the seed and the texts straight from this test bundle (folder references in
        // project.yml).
        app.launchEnvironment["UITESTING_APPSTORE_SEED"] = seedURL.path
        let texts = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AppStoreBooks", withExtension: nil),
                                  "AppStoreBooks missing from the UI test bundle")
        app.launchEnvironment["UITESTING_BOOK_TEXTS"] = texts.path
        app.launch()
        let rows = app.descendants(matching: .any).matching(identifier: "libraryRow")
        require(rows.element(boundBy: library.count), 60, "Library with the seeded books did not appear", in: app)
        // Checked at the end, so that a wrong Library still yields all three captures to look at.
        let labels = rows.allElementsBoundByIndex.map(\.label)
        sleep(2)
        capture("iphone-1-library")
        assertTitlesFit("iphone-1-library", in: app)

        let first = rows.element(boundBy: 0)
        let sampleRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'libraryRow' AND label BEGINSWITH %@", sampleTitle)).firstMatch
        (sampleRow.exists ? sampleRow : first).tap()
        require(app.descendants(matching: .any)["bookDetail"], 20, "book details did not open", in: app)
        sleep(2)
        capture("iphone-2-book-details")
        assertTitlesFit("iphone-2-book-details", in: app)

        // The tab bar's second item (Library, Reading, Settings): found by position, not by its localized label.
        let readingTab = app.tabBars.buttons.element(boundBy: 1)
        require(readingTab, 20, "Reading tab button missing", in: app)
        readingTab.tap()
        require(app.descendants(matching: .any)["typographyPreview"], 30, "Reading tab did not show its preview", in: app)
        sleep(2)
        capture("iphone-3-reading")
        assertTitlesFit("iphone-3-reading", in: app)

        XCTAssertTrue(labels.first?.hasPrefix(sampleTitle) == true, "the sample book should be on top: \(labels)")
        // The texts were read (sizes in KB, not bytes).
        for label in labels {
            XCTAssertFalse(label.contains("bytes"), "book seeded without a full text: \(label)")
        }
    }
}
