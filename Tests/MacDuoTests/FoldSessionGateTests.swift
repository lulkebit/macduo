import XCTest
@testable import MacDuo

final class FoldSessionGateTests: XCTestCase {
    func testEnablingAtAnAlreadyFoldedRestingAngleNeverCaptures() {
        var gate = FoldSessionGate()
        for _ in 0..<(60 * 60) {
            XCTAssertEqual(gate.update(angle: 23, startAngle: 100), .none)
        }
        XCTAssertEqual(gate.update(angle: 21, startAngle: 100), .begin)
        for _ in 0..<60 {
            XCTAssertEqual(gate.update(angle: 22, startAngle: 100), .none)
        }
    }

    func testQuantizedClosingStartsOnceAndPausesOrReversalsRetainSession() {
        var gate = FoldSessionGate()
        for angle in [110.0, 105, 102, 101, 100] {
            XCTAssertEqual(gate.update(angle: angle, startAngle: 100), .none)
        }
        XCTAssertEqual(gate.update(angle: 98, startAngle: 100), .begin)
        for angle in [90.0, 80, 80, 81, 80, 30, 30, 45, 70, 98, 99.9] {
            XCTAssertEqual(gate.update(angle: angle, startAngle: 100), .none)
        }
        XCTAssertEqual(gate.update(angle: 100, startAngle: 100), .end)
        XCTAssertEqual(gate.update(angle: 102, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 101, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 98, startAngle: 100), .begin)
    }

    func testOpeningAfterWakeBeginsOnlyAfterFreshPhysicalMovement() {
        var gate = FoldSessionGate()
        XCTAssertEqual(gate.update(angle: 50, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 48, startAngle: 100), .begin)
        gate.reset()
        XCTAssertEqual(gate.update(angle: 12, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 12, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 14, startAngle: 100), .begin)
        XCTAssertEqual(gate.update(angle: 100, startAngle: 100), .end)
    }

    func testSmallMovementAccumulatesButRestingNoiseDoesNot() {
        var gate = FoldSessionGate()
        XCTAssertEqual(gate.update(angle: 50, startAngle: 100), .none)
        for _ in 0..<60 {
            for angle in [50.2, 49.7, 50.4, 49.6, 50] {
                XCTAssertEqual(gate.update(angle: angle, startAngle: 100), .none)
            }
        }
        for angle in [49.75, 49.5, 49.25, 49, 48.75, 48.5, 48.25] {
            XCTAssertEqual(gate.update(angle: angle, startAngle: 100), .none)
        }
        XCTAssertEqual(gate.update(angle: 48, startAngle: 100), .begin)
    }

    func testMovementAndRestAboveThresholdNeverCapture() {
        var gate = FoldSessionGate()
        for _ in 0..<60 {
            for angle in [140.0, 120, 100, 105, 125, 125] {
                XCTAssertEqual(gate.update(angle: angle, startAngle: 100), .none)
            }
        }
    }

    func testFailureRequiresOpeningToRearmAndCannotHammerRetries() {
        var gate = FoldSessionGate()
        XCTAssertEqual(gate.update(angle: 50, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 48, startAngle: 100), .begin)
        gate.captureFailed()
        for angle in [48.0, 20, 80, 20, 99, 99.9, 80, 99.99] {
            XCTAssertEqual(gate.update(angle: angle, startAngle: 100), .none)
        }
        XCTAssertEqual(gate.update(angle: 100, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 100, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 99.5, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 98, startAngle: 100), .begin)
    }

    func testExplicitResetAfterFailureStillNeedsNewMovement() {
        var gate = FoldSessionGate()
        _ = gate.update(angle: 50, startAngle: 100)
        _ = gate.update(angle: 49, startAngle: 100)
        gate.captureFailed()
        gate.reset()
        XCTAssertEqual(gate.update(angle: 49, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 49, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 51, startAngle: 100), .begin)
    }

    func testExplicitSnapshotTestFailureAlsoBlocksIdleGateRetries() {
        var gate = FoldSessionGate()
        XCTAssertEqual(gate.update(angle: 23, startAngle: 100), .none)
        gate.captureFailed()
        XCTAssertEqual(gate.update(angle: 24, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 20, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 100, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 98, startAngle: 100), .begin)
    }

    func testThresholdChangesAloneCannotStartACapture() {
        var gate = FoldSessionGate()
        _ = gate.update(angle: 120, startAngle: 100)
        _ = gate.update(angle: 110, startAngle: 100)
        XCTAssertEqual(gate.update(angle: 110, startAngle: 125), .none)
        XCTAssertEqual(gate.update(angle: 110, startAngle: 125), .none)
        XCTAssertEqual(gate.update(angle: 108, startAngle: 125), .begin)
        XCTAssertEqual(gate.update(angle: 109, startAngle: 100), .end)
        XCTAssertEqual(gate.update(angle: 109, startAngle: 125), .none)
    }

    func testReturningExactlyToReferenceEndsSessionAndNextCloseNeedsFreshSnapshot() {
        var gate = FoldSessionGate()
        XCTAssertEqual(gate.update(angle: 100, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 60, startAngle: 100), .begin)
        XCTAssertEqual(gate.update(angle: 100, startAngle: 100), .end)
        XCTAssertEqual(gate.update(angle: 99, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 98, startAngle: 100), .begin)
    }

    func testObservedOneDegreeSensorJitterNeverCapturesInEitherDirection() {
        for baseline in [40.0, 41] {
            var gate = FoldSessionGate()
            XCTAssertEqual(gate.update(angle: baseline, startAngle: 100), .none)
            for _ in 0..<600 {
                XCTAssertEqual(gate.update(angle: 40, startAngle: 100), .none)
                XCTAssertEqual(gate.update(angle: 41, startAngle: 100), .none)
            }
            let movedAngle = baseline == 40 ? 42.0 : 39.0
            XCTAssertEqual(gate.update(angle: movedAngle, startAngle: 100), .begin)
        }
    }

    func testNoiseAroundReferenceCannotRepeatedlyRequestSnapshots() {
        var gate = FoldSessionGate()
        XCTAssertEqual(gate.update(angle: 100, startAngle: 100), .none)
        for _ in 0..<60 {
            for angle in [100.7, 99.6, 100.1, 99.1, 100, 99.99] {
                XCTAssertEqual(gate.update(angle: angle, startAngle: 100), .none)
            }
        }
        XCTAssertEqual(gate.update(angle: 98, startAngle: 100), .begin)
        XCTAssertEqual(gate.update(angle: 100, startAngle: 100), .end)
        XCTAssertEqual(gate.update(angle: 99.2, startAngle: 100), .none)
    }

    func testInvalidSamplesNeverBeginAndEndAnExistingSessionSafely() {
        var gate = FoldSessionGate()
        for angle in [Double.nan, .infinity, -.infinity, -1, 181] {
            XCTAssertEqual(gate.update(angle: angle, startAngle: 100), .none)
        }
        XCTAssertEqual(gate.update(angle: 50, startAngle: 100), .none)
        XCTAssertEqual(gate.update(angle: 48, startAngle: 100), .begin)
        XCTAssertEqual(gate.update(angle: .nan, startAngle: 100), .end)
        XCTAssertEqual(gate.update(angle: 49, startAngle: 100), .none)
        for threshold in [Double.nan, .infinity, 0, 8, 181] {
            XCTAssertEqual(gate.update(angle: 48, startAngle: threshold), .none)
        }
    }
}
