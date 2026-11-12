import XCTest
@testable import FolitoWatch

/// The reader's left-edge swipe back (#118): only a clear rightward drag that starts at the edge leaves the book.
final class EdgeSwipeBackTests: XCTestCase {
    private func swipe(x: CGFloat, dx: CGFloat, dy: CGFloat = 0, predicted: CGSize? = nil, minX: CGFloat = 0) -> Bool {
        EdgeSwipeBack.isBackSwipe(startX: x, screenMinX: minX, translation: CGSize(width: dx, height: dy),
                                  predictedEndTranslation: predicted)
    }

    func testRightwardDragFromTheEdgeGoesBack() {
        XCTAssertTrue(swipe(x: 1, dx: 120))
        XCTAssertTrue(swipe(x: EdgeSwipeBack.edgeWidth, dx: EdgeSwipeBack.minDistance))
        XCTAssertTrue(swipe(x: 2, dx: 80, dy: 30), "A slightly diagonal swipe still counts")
    }

    func testDragStartingAwayFromTheEdgeDoesNot() {
        XCTAssertFalse(swipe(x: EdgeSwipeBack.edgeWidth + 1, dx: 150))
        XCTAssertFalse(swipe(x: 90, dx: 80))
        // Measured from the screen's own left edge.
        XCTAssertTrue(swipe(x: 105, dx: 80, minX: 100))
        XCTAssertFalse(swipe(x: 5, dx: 80, minX: -20))
    }

    func testShortOrLeftwardDragDoesNot() {
        XCTAssertFalse(swipe(x: 1, dx: EdgeSwipeBack.minDistance - 1))
        XCTAssertFalse(swipe(x: 1, dx: -80))
        XCTAssertFalse(swipe(x: 1, dx: 0))
    }

    func testVerticalScrollFromTheEdgeDoesNot() {
        XCTAssertFalse(swipe(x: 1, dx: 10, dy: 120))
        XCTAssertFalse(swipe(x: 1, dx: 60, dy: -60))
        XCTAssertFalse(swipe(x: 1, dx: 50, dy: 50 * EdgeSwipeBack.maxSlope + 1))
    }

    func testQuickFlickUsesThePredictedEnd() {
        XCTAssertTrue(swipe(x: 1, dx: 25, predicted: CGSize(width: 90, height: 5)))
        XCTAssertFalse(swipe(x: 1, dx: 25), "Without a prediction a short drag is not enough")
        XCTAssertFalse(swipe(x: 1, dx: 25, predicted: CGSize(width: 30, height: 0)), "Predicted end too short")
        XCTAssertFalse(swipe(x: 1, dx: EdgeSwipeBack.minFlickDistance - 1, predicted: CGSize(width: 120, height: 0)))
        XCTAssertFalse(swipe(x: 1, dx: 25, predicted: CGSize(width: 90, height: 90)), "Predicted end too steep")
    }

    // MARK: Tap forwarding from the edge strip

    private let frames: [Int: BlockFrame] = [
        3: BlockFrame(minY: -40, maxY: 20, width: 180),
        4: BlockFrame(minY: 26, maxY: 120, width: 180),
        5: BlockFrame(minY: 126, maxY: 300, width: 180),
    ]

    private func target(_ x: CGFloat, _ y: CGFloat, origin: CGPoint = .zero, margin: CGFloat = 4) -> (index: Int, location: CGPoint)? {
        EdgeSwipeBack.tapTarget(at: CGPoint(x: x, y: y), scrollOrigin: origin, contentMinX: margin, frames: frames)
    }

    func testTapFindsTheBlockUnderItByY() {
        XCTAssertEqual(target(8, 0)?.index, 3, "A block partly scrolled above the top still takes taps on its visible part")
        XCTAssertEqual(target(8, 26)?.index, 4, "Top edge belongs to the block")
        XCTAssertEqual(target(8, 119.5)?.index, 4)
        XCTAssertEqual(target(8, 200)?.index, 5)
    }

    func testTapOverNoBlockFindsNothing() {
        XCTAssertNil(target(8, 22), "Paragraph spacing")
        XCTAssertNil(target(8, 120), "Bottom edge is exclusive")
        XCTAssertNil(target(8, -60), "Above the first measured block")
        XCTAssertNil(target(8, 400), "Below the last measured block")
        XCTAssertNil(EdgeSwipeBack.tapTarget(at: CGPoint(x: 8, y: 50), scrollOrigin: .zero, contentMinX: 4, frames: [:]))
    }

    func testTapLocationIsInTheBlocksOwnCoordinates() {
        let t = target(8, 50)
        XCTAssertEqual(t?.location.x, 4, "Global x minus the text margin")
        XCTAssertEqual(t?.location.y, 24, "Scroll-space y minus the block's top")
        XCTAssertEqual(target(1, 0)?.location, CGPoint(x: 0, y: 40), "A tap in the margin clamps to the line start")
    }

    func testTapIsConvertedFromGlobalToTheScrollViewsSpace() {
        // The scroll view starts 10 pt right and 30 pt down on screen: global (16, 80) is (6, 50) in its space.
        let t = target(16, 80, origin: CGPoint(x: 10, y: 30), margin: 2)
        XCTAssertEqual(t?.index, 4)
        XCTAssertEqual(t?.location, CGPoint(x: 4, y: 24))
        XCTAssertNil(target(16, 52, origin: CGPoint(x: 10, y: 30)), "Global y 52 is the spacing at 22 in scroll space")
    }
}
