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
}
