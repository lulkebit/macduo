import XCTest
import ScreenCaptureKit
@testable import MacDuo

final class ScreenCapturePermissionTests: XCTestCase {
    private var denial: NSError {
        NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
    }

    func testActualScreenCaptureDenialIsRecognized() {
        XCTAssertTrue(ScreenCapturePermission.isDenied(denial))
        let wrapped = NSError(domain: "CaptureWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: denial])
        XCTAssertTrue(ScreenCapturePermission.isDenied(wrapped))
    }

    func testDisplayGPUAndOtherErrorsAreNotPermissionDenials() {
        XCTAssertFalse(ScreenCapturePermission.isDenied(DesktopEffectError.builtInDisplayUnavailable))
        XCTAssertFalse(ScreenCapturePermission.isDenied(DesktopEffectError.metalUnavailable))
        XCTAssertFalse(ScreenCapturePermission.isDenied(NSError(domain: SCStreamErrorDomain, code: -3802)))
        XCTAssertFalse(ScreenCapturePermission.isDenied(NSError(domain: "UnrelatedDomain", code: -3801)))
        XCTAssertFalse(ScreenCapturePermission.isDenied(CancellationError()))
    }

    func testDeniedPermissionBlocksLaterFoldsEvenAfterGateResets() {
        var access = ScreenCapturePermissionRecovery()
        var gate = FoldSessionGate()
        var requests = 0
        func move(_ angle: Double) {
            guard access.allowsAutomaticCapture else { return }
            if gate.update(angle: angle, startAngle: 100) == .begin { requests += 1 }
        }
        move(100)
        move(97)
        XCTAssertEqual(requests, 1)
        access.captureDenied()
        gate.captureFailed()

        // Reopening the lid and resets caused by wake, display changes,
        // toggling the effect, calibration or sensor reconnection stay blocked.
        for _ in 0..<20 {
            move(110)
            move(80)
            gate.reset()
            move(110)
            move(70)
        }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(access.requiresExplicitRetry)
    }

    func testDenialSurvivesRelaunchUntilAnExplicitRequestSucceeds() {
        var access = ScreenCapturePermissionRecovery()
        access.captureDenied()
        var restored = ScreenCapturePermissionRecovery(requiresExplicitRetry: access.requiresExplicitRetry)
        XCTAssertFalse(restored.allowsAutomaticCapture)
        // Another failed explicit attempt must not reopen automatic capture.
        restored.captureDenied()
        XCTAssertFalse(restored.allowsAutomaticCapture)
        restored.captureSucceeded()
        XCTAssertTrue(restored.allowsAutomaticCapture)
        XCTAssertFalse(restored.requiresExplicitRetry)
    }

    func testSuccessfulRetryStillRequiresFreshLidMovement() {
        var access = ScreenCapturePermissionRecovery(requiresExplicitRetry: true)
        var gate = FoldSessionGate()
        access.captureSucceeded()
        gate.reset()
        // Permission testing discards its image and seeds the current angle.
        XCTAssertEqual(gate.update(angle: 80, startAngle: 100), .none)
        for angle in [80.0, 79, 80, 81, 80] {
            XCTAssertEqual(gate.update(angle: angle, startAngle: 100), .none)
        }
        XCTAssertTrue(access.allowsAutomaticCapture)
        XCTAssertEqual(gate.update(angle: 77, startAngle: 100), .begin)
    }
}
