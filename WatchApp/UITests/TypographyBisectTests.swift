import XCTest

// TEMPORARY: times the Typography editor per debug variant (TYPOGRAPHY_BISECT) to find what keeps the app from
// idling. Prints only; removed before merging.
final class TypographyBisectTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 300
    }

    @MainActor
    private func trial(_ variant: Int) {
        for round in 1...2 {
            let app = XCUIApplication()
            app.launchArguments += ["-UITesting"]
            app.launchEnvironment["TYPOGRAPHY_BISECT"] = "\(variant)"
            app.launch()
            WatchUI.openSettings(app)
            let link = WatchUI.element("typographyLink", in: app)
            WatchUI.scrollToHittable(link, in: app)
            let start = Date()
            link.tap() // waits (up to 60 s) for the app to idle
            let elapsed = Date().timeIntervalSince(start)
            FileHandle.standardOutput.write(Data("BISECT variant=\(variant) round=\(round) tap+idle=\(Int(elapsed)) s\n".utf8))
            app.terminate()
        }
    }

    @MainActor func testVariant0Full() { trial(0) }
    @MainActor func testVariant1NoPreview() { trial(1) }
    @MainActor func testVariant2NoPickers() { trial(2) }
    @MainActor func testVariant3NoCustomSteppers() { trial(3) }
    @MainActor func testVariant4PreviewIgnoreChildren() { trial(4) }
    @MainActor func testVariant5PreviewNoAccessibilityReader() { trial(5) }
    @MainActor func testVariant6NoTextSizeStepper() { trial(6) }
}
