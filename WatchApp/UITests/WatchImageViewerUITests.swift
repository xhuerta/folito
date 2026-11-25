import XCTest

/// Pictures in the text (#71), on the illustrated seed (`-UITestingSeedIllustratedBook`): the picture is in the
/// flow with its description as its label, a picture that cannot be shown reads "Image", a tap opens the viewer,
/// the viewer zooms with a double tap, and closing it returns to the same reading position. The seed's first picture
/// is right under a one-line heading, on screen when the book opens; a later one is reached by scrolling.
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
        XCTAssertTrue(WatchUI.picture("Image", in: app).exists, "A picture without a description reads \u{201C}Image\u{201D}")
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

    /// A picture further on: scrolled to in short slow drags, opened, closed.
    @MainActor
    func testScrollingToALaterPictureOpensIt() throws {
        let app = WatchUI.launch(seedSampleBook: true, extraArguments: WatchUI.illustratedBookArguments)
        WatchUI.openReader(app)
        guard WatchUI.openImageViewer(app, label: WatchUI.laterIllustrationLabel) else { return }
        XCTAssertEqual(WatchUI.element("imageViewerPicture", in: app).label, WatchUI.laterIllustrationLabel)
        WatchUI.element("imageViewerClose", in: app).tap()
        XCTAssertTrue(WatchUI.picture(WatchUI.laterIllustrationLabel, in: app).waitForExistence(timeout: 5),
                      "Closing did not return to the reader")
    }
}
