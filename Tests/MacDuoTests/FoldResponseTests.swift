import XCTest
@testable import MacDuo

final class FoldResponseTests: XCTestCase {
    func testPhysicalEndpointsAndMonotonicClosing() {
        XCTAssertEqual(FoldResponse.progress(angle: 140), 0)
        XCTAssertEqual(FoldResponse.progress(angle: 100), 0)
        XCTAssertEqual(FoldResponse.progress(angle: 8), 1)
        XCTAssertEqual(FoldResponse.progress(angle: 0), 1)
        var previous = 0.0
        for angle in stride(from: 140.0, through: 0.0, by: -0.25) {
            let progress = FoldResponse.progress(angle: angle)
            XCTAssertGreaterThanOrEqual(progress, previous)
            XCTAssertTrue((0...1).contains(progress))
            previous = progress
        }
    }

    func testCurveIsReversibleAndThresholdIsConfigurable() {
        XCTAssertEqual(FoldResponse.progress(angle: 54), 0.5, accuracy: 0.00001)
        XCTAssertEqual(FoldResponse.progress(angle: 104), 0)
        // A lower threshold keeps a more closed working position clear.
        XCTAssertEqual(FoldResponse.progress(angle: 90, startAngle: 80), 0)
        let closing = [99.0, 80, 54, 20, 8].map { FoldResponse.progress(angle: $0) }
        let opening = [8.0, 20, 54, 80, 99].map { FoldResponse.progress(angle: $0) }
        XCTAssertEqual(closing, opening.reversed())
    }

    func testInvalidInputIsSafe() {
        XCTAssertEqual(FoldResponse.progress(angle: .nan), 0)
        XCTAssertEqual(FoldResponse.progress(angle: .infinity), 0)
        XCTAssertEqual(FoldResponse.progress(angle: 50, startAngle: 8), 0)
        XCTAssertEqual(FoldResponse.progress(angle: 50, startAngle: .nan), 0)
    }

    func testSmoothingHasNoOvershootAndReversesImmediately() {
        let closing = FoldResponse.smooth(current: 0, target: 1, elapsed: 1.0 / 60)
        XCTAssertTrue((0...1).contains(closing))
        let opening = FoldResponse.smooth(current: closing, target: 0, elapsed: 1.0 / 60)
        XCTAssertLessThan(opening, closing)
        XCTAssertGreaterThanOrEqual(opening, 0)
        XCTAssertEqual(FoldResponse.smooth(current: 0.4, target: 1, elapsed: 0), 0.4)
        XCTAssertEqual(FoldResponse.smooth(current: 0.4, target: .nan, elapsed: 1), 0.4)
    }
}
