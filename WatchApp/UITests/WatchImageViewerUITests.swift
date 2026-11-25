import XCTest

/// Pictures in the text (#71), on the illustrated seed (`-UITestingSeedIllustratedBook`): the picture is in the
/// flow with its description as its label, a picture that cannot be shown reads "Image", a tap opens the viewer,
/// the viewer zooms with a double tap, and closing it returns to the same reading position.
final class WatchImageViewerUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testPictureOpensAndClosingKeepsThePosition() throws {
        let app = WatchUI.launch(seedSampleBook: true,
                                 extraArguments: WatchUI.illustratedBookArguments + [WatchUI.readerPositionArgument])
        WatchUI.openReader(app)
        let picture = WatchUI.illustration(in: app)
        XCTAssertTrue(picture.waitForExistence(timeout: 5), "The picture is not in the text")
        // The seed's second picture has no file on purpose (`BlockImage(id: nil)`): it shows the fallback.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "readerBlock")
            .matching(NSPredicate(format: "label == %@", "Image")).element(boundBy: 0).exists,
                      "A picture without a description reads \u{201C}Image\u{201D}")
        // Bring the picture into view first, so the position compared is the one the viewer opens over.
        XCTAssertTrue(WatchUI.scrollIntoMiddle(picture, in: app), "The picture could not be scrolled into view")
        let before = WatchUI.settledPosition(in: app)
        XCTAssertNotNil(before, "The reader did not settle")
        guard WatchUI.openImageViewer(app) else { return }
        let shown = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shown.name = "watch-image-viewer"
        shown.lifetime = .keepAlways
        add(shown)
        let viewer = WatchUI.element("imageViewerPicture", in: app)
        XCTAssertTrue(viewer.exists)
        XCTAssertEqual(viewer.label, WatchUI.illustrationLabel)
        viewer.doubleTap()
        let zoomed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        zoomed.name = "watch-image-viewer-zoomed"
        zoomed.lifetime = .keepAlways
        add(zoomed)
        WatchUI.element("imageViewerClose", in: app).tap()
        XCTAssertTrue(picture.waitForExistence(timeout: 5), "Closing did not return to the reader")
        XCTAssertEqual(WatchUI.settledPosition(in: app), before, "Closing the viewer moved the reading position")
    }
}
