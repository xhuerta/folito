import CoreText
import UIKit
import XCTest

/// The Apple Watch screenshots of the App Store listing (docs/appstore/SCREENSHOTS.md), in one language:
///
/// 1. `watch-1-reader`: the reader at the opening of chapter 1 of the language's sample book, scrolled just enough
///    for the top bar to hide (the system time shows above the page-coloured clock band; no book title).
/// 2. `watch-2-word-lookup` / `watch-2a-word-picker`: the definition of the language's word, and the word picker on it.
/// 3. `watch-3-library`: the Library, with title covers and reading progress.
/// 4. `watch-4-sepia`: the reader further on in the "Comfortable" preset with the sepia theme, top bar hidden.
/// 5. `watch-5-menu`: the reader menu with "Go to Synced Position" (an offline stand-in sync service).
///
/// The language comes from the test runner's environment, `SCREENSHOT_LANG` (xcodebuild passes
/// `TEST_RUNNER_SCREENSHOT_LANG`; default `en`). The app is launched in it (`-AppleLanguages`) with
/// `-UITestingSeedAppStore` (Debug builds only) and that language's seed, `AppStoreSeeds/<lang>.json`
/// (scripts/make_appstore_seeds.py), in `UITESTING_APPSTORE_SEED`. Elements are found by accessibility
/// identifier, never by English labels. Every captured screen with a navigation title is checked for a title
/// that is cut (spec: no screenshot may show a truncated title).
final class WatchAppStoreScreenshotTests: XCTestCase {
    private struct Seed {
        let language: String
        let appleLanguage: String
        let appleLocale: String
        let word: String
        let lookupChapter: Int
        let lookupBlock: Int
        let probe: String
        let path: String
    }

    private var seed: Seed!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let lang = ProcessInfo.processInfo.environment["SCREENSHOT_LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en"
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AppStoreSeeds", withExtension: nil),
                                   "AppStoreSeeds missing from the UI test bundle")
        let url = folder.appendingPathComponent("\(lang).json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let lookup = try XCTUnwrap(json["lookup"] as? [String: Any])
        seed = Seed(language: lang,
                    appleLanguage: try XCTUnwrap(json["appleLanguage"] as? String),
                    appleLocale: try XCTUnwrap(json["appleLocale"] as? String),
                    word: try XCTUnwrap(lookup["word"] as? String),
                    lookupChapter: try XCTUnwrap(lookup["chapter"] as? Int),
                    lookupBlock: try XCTUnwrap(lookup["block"] as? Int),
                    probe: try XCTUnwrap(lookup["probe"] as? String),
                    path: url.path)
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedAppStore", "-AppleLanguages", "(\"\(seed.appleLanguage)\")",
                                "-AppleLocale", seed.appleLocale] + extra
        app.launchEnvironment["UITESTING_APPSTORE_SEED"] = seed.path
        app.launch()
        if !WatchUI.libraryRow(in: app).waitForExistence(timeout: 45) {
            WatchUI.fail("Library rows did not appear within 45 s of the launch", in: app)
        }
        return app
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Captures once two consecutive screenshots are identical, that is when nothing on screen is moving
    /// (scrolling, a marquee title, covers loading). After `timeout` seconds the last screenshot is taken as it is.
    @MainActor
    private func captureWhenStill(_ name: String, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        var shot = XCUIScreen.main.screenshot()
        var previous = Self.pixels(of: shot.image)
        var still = false
        while Date() < deadline {
            usleep(300_000)
            shot = XCUIScreen.main.screenshot()
            let current = Self.pixels(of: shot.image)
            still = current != nil && current == previous
            previous = current
            if still { break }
        }
        if !still { print("::warning::\(name): the screen did not stop moving within \(Int(timeout)) s") }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The RGBA bytes of an image, for comparing two screenshots.
    private static func pixels(of image: UIImage) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = Data(count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? data : nil
    }

    /// Fails when a navigation title on screen is cut: its text, measured in a font no larger than the title's,
    /// is wider than its element, or the element reaches past the screen (a marquee mid-scroll).
    @MainActor
    private func assertTitlesFit(_ screen: String, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let font = UIFont.systemFont(ofSize: 13, weight: .regular)
        let key = NSAttributedString.Key(kCTFontAttributeName as String)
        for title in app.navigationBars.staticTexts.allElementsBoundByIndex where title.exists && !title.label.isEmpty {
            let frame = title.frame
            guard frame.width > 0 else { continue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: title.label, attributes: [key: font]))
            let needed = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            XCTAssertFalse(needed > frame.width + 1 || frame.minX < window.minX - 0.5 || frame.maxX > window.maxX + 0.5,
                           "\(screen) [\(seed.language)]: the title \u{201C}\(title.label)\u{201D} is cut "
                           + "(text \(Int(needed)) pt, element \(frame), screen \(window))")
        }
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, hittable: Bool, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate { _, _ in (element.exists && element.isHittable) == hittable }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    /// Scrolls the reader down until its top bar hides, then checks that the clock band covers the time area:
    /// the reader screenshots show no book title at all.
    @MainActor
    private func hideReaderBar(_ app: XCUIApplication) {
        let options = WatchUI.element("readerOptionsButton", in: app)
        XCTAssertTrue(waitFor(options, hittable: true), "Reading Options button should show when the book opens")
        var nudges = 0
        while nudges < 6 && !waitFor(options, hittable: false, timeout: nudges == 0 ? 0.5 : 2) {
            WatchUI.nudgeUp(app)
            nudges += 1
        }
        guard waitFor(options, hittable: false) else {
            return WatchUI.fail("The reader's top bar did not hide after scrolling", in: app)
        }
        guard WatchUI.element("clockBand", in: app).waitForExistence(timeout: 3) else {
            return WatchUI.fail("The clock band should cover the time while the bar is hidden", in: app)
        }
    }

    @MainActor
    func testLibrary() {
        let app = launch()
        captureWhenStill("watch-3-library")
        assertTitlesFit("watch-3-library", in: app)
        app.terminate()
    }

    @MainActor
    func testReader() {
        let app = launch()
        WatchUI.openReader(app)
        hideReaderBar(app)
        captureWhenStill("watch-1-reader")
        app.terminate()
    }

    @MainActor
    func testSepiaReader() {
        let app = launch(["-UITestingAppStoreSepia"])
        WatchUI.openReader(app)
        hideReaderBar(app)
        captureWhenStill("watch-4-sepia")
        app.terminate()
    }

    @MainActor
    func testReaderMenu() {
        let app = launch(["-UITestingSimulateSync"])
        WatchUI.openReader(app)
        let options = WatchUI.element("readerOptionsButton", in: app)
        XCTAssertTrue(waitFor(options, hittable: true, timeout: 10), "Reading Options button missing")
        options.tap()
        let synced = WatchUI.element("goToSyncedPositionButton", in: app)
        guard synced.waitForExistence(timeout: 10) else {
            return WatchUI.fail("The reader menu did not offer Go to Synced Position", in: app)
        }
        XCTAssertTrue(WatchUI.scrollToHittable(synced, in: app), "Go to Synced Position not reachable")
        captureWhenStill("watch-5-menu")
        assertTitlesFit("watch-5-menu", in: app)
        app.terminate()
    }

    @MainActor
    func testWordLookup() {
        let app = launch()
        WatchUI.openReader(app)
        XCTAssertEqual(seed.lookupChapter, 0, "the word must be in chapter 1, where the reader opens")
        let paragraph = app.descendants(matching: .any).matching(identifier: "readerBlock").element(boundBy: seed.lookupBlock)
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5), "paragraph \(seed.lookupBlock) missing")
        let next = WatchUI.element("nextWordButton", in: app)
        // Tapping a paragraph opens the word picker on the tapped word: tap its first word (top leading corner).
        // A paragraph below the screen is scrolled to first; that hides the bar, and the first tap then only
        // shows it again, so tap up to three times.
        WatchUI.scrollToHittable(paragraph, in: app)
        for _ in 0..<3 where !next.exists {
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.04)).tap()
            _ = next.waitForExistence(timeout: 4)
        }
        guard next.exists else { return WatchUI.fail("word picker did not open", in: app) }

        // Move the cursor to the word: its accessibility value names the selected word.
        let cursor = WatchUI.element("selectedWord", in: app)
        let word = seed.word
        func onWord() -> Bool {
            ((cursor.value as? String) ?? "").range(of: word, options: [.caseInsensitive]) != nil
        }
        var steps = 0
        while steps < 80 && !onWord() && next.isEnabled {
            next.tap()
            steps += 1
            usleep(300_000)
        }
        sleep(1)
        capture("watch-2a-word-picker")
        guard onWord() else { return WatchUI.fail("cursor did not reach \u{201C}\(word)\u{201D}", in: app) }

        let lookUp = WatchUI.element("lookUpButton", in: app)
        XCTAssertTrue(WatchUI.scrollToHittable(lookUp, in: app), "Look Up button not reachable")
        lookUp.tap()
        let definition = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", seed.probe)).element(boundBy: 0)
        let found = definition.waitForExistence(timeout: 10)
        sleep(1)
        capture("watch-2-word-lookup")
        guard found else { return WatchUI.fail("definition of \u{201C}\(word)\u{201D} not shown", in: app) }
        assertTitlesFit("watch-2-word-lookup", in: app)
        app.terminate()
    }
}
