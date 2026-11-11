import UIKit
import XCTest

/// The Apple Watch screenshots of the App Store listing (docs/appstore/SCREENSHOTS.md): the reader, the word
/// lookup with a definition, and the Library. Launched with `-UITestingSeedAppStore` (Debug builds only): the
/// opening of the English sample book, three more public-domain titles (with title covers, part-read) and a
/// small sample dictionary.
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

    /// Captures once two consecutive screenshots are identical, that is when nothing on screen is moving.
    /// The reader's navigation title is longer than the space beside the clock, so watchOS scrolls it as a
    /// marquee: a capture taken at a fixed delay can catch it mid-scroll ("and Prejudi"). The marquee rests
    /// only at its start, so a still screen shows the title from its first letter. After `timeout` seconds
    /// the last screenshot is taken as it is.
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

    @MainActor
    private func labelled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[label].firstMatch
        if button.exists { return button }
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).element(boundBy: 0)
    }

    @MainActor
    func testLibrary() {
        let app = launch()
        captureWhenStill("watch-3-library")
        app.terminate()
    }

    @MainActor
    func testReaderAndWordLookup() {
        let app = launch()
        WatchUI.openReader(app)
        captureWhenStill("watch-1-reader")

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
