import XCTest

/// The watch Library with Settings > Show Covers on and off, at the default and the largest accessibility text
/// size (`-UITestingSeedCovers`: three books with generated covers and the cover-less sample book). Screenshots
/// only; macos.yml runs this on the smallest and the largest watch simulator and exports the `covers-watch`
/// artifact.
final class WatchCoversScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func capture(coversOn: Bool, largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedCovers"]
        if !coversOn { app.launchArguments += ["-UITestingCoversOff"] }
        if largeText { app.launchArguments += WatchUI.accessibilityXXXLArguments }
        app.launch()
        XCTAssertTrue(WatchUI.libraryRow(in: app).waitForExistence(timeout: 20), "Library rows did not appear")
        sleep(1)
        let width = Int(app.windows.firstMatch.frame.width.rounded())
        let name = "covers-watch-\(width)pt-\(coversOn ? "on" : "off")-\(largeText ? "ax" : "default")"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    @MainActor
    func testLibraryCoversOnDefault() { capture(coversOn: true, largeText: false) }

    @MainActor
    func testLibraryCoversOffDefault() { capture(coversOn: false, largeText: false) }

    @MainActor
    func testLibraryCoversOnLargeText() { capture(coversOn: true, largeText: true) }

    @MainActor
    func testLibraryCoversOffLargeText() { capture(coversOn: false, largeText: true) }
}
