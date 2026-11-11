import XCTest

/// The Apple Watch screenshots of the App Store listing (docs/appstore/SCREENSHOTS.md): the reader, the word
/// lookup with a definition, and the Library. Launched with `-UITestingSeedAppStore` (Debug builds only): the
/// opening of the English sample book, three more public-domain titles and a small sample dictionary.
/// macos.yml runs this on one watch simulator whose screen is a size App Store Connect accepts and exports
/// the attachments as the `app-store-screenshots` artifact.
final class WatchAppStoreScreenshotTests: XCTestCase {
    private static let word = "acknowledged"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedAppStore", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(WatchUI.libraryRow(in: app).waitForExistence(timeout: 20), "Library rows did not appear")
        return app
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func labelled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[label].firstMatch
        if button.exists { return button }
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).element(boundBy: 0)
    }

    @MainActor
    func testLibrary() {
        let app = launch()
        sleep(2)
        capture("watch-3-library")
        app.terminate()
    }

    @MainActor
    func testReaderAndWordLookup() {
        let app = launch()
        WatchUI.openReader(app)
        sleep(2)
        capture("watch-1-reader")

        // The first paragraph (the chapter heading is block 0): tapping it opens the word picker.
        let paragraph = app.descendants(matching: .any).matching(identifier: "readerBlock").element(boundBy: 1)
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5), "first paragraph missing")
        paragraph.tap()
        let next = labelled("Next Word", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: 10), "word picker did not open. Tree:\n\(app.debugDescription)")

        // Move the cursor to the word. The cursor is one element labelled "Selected word" whose value starts
        // with the word; if it cannot be read, the word is five steps from the start of the paragraph.
        let cursor = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Selected word")).element(boundBy: 0)
        func onWord() -> Bool { ((cursor.value as? String) ?? "").hasPrefix(Self.word) }
        var steps = 0
        while steps < 12 {
            if cursor.exists ? onWord() : steps == 5 { break }
            next.tap()
            steps += 1
            usleep(400_000)
        }
        sleep(1)
        capture("watch-2a-word-picker")
        XCTAssertTrue(!cursor.exists || onWord(), "cursor did not reach \(Self.word). Tree:\n\(app.debugDescription)")

        let lookUp = labelled("Look Up", in: app)
        XCTAssertTrue(WatchUI.scrollToHittable(lookUp, in: app), "Look Up button not reachable")
        lookUp.tap()
        let definition = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "accept or admit")).element(boundBy: 0)
        let found = definition.waitForExistence(timeout: 10)
        sleep(1)
        capture("watch-2-word-lookup")
        XCTAssertTrue(found, "definition not shown. Tree:\n\(app.debugDescription)")
        app.terminate()
    }
}
