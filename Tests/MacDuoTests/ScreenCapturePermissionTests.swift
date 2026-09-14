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

    func testActivationAndDialogDismissalDoNotRetryWithoutASettingsVisit() {
        var recovery = ScreenCapturePermissionRecovery()
        recovery.settingsBecameActive()
        recovery.captureDenied()
        XCTAssertFalse(recovery.consumeRetryOnReturn())
        recovery.requestActivation()
        recovery.captureDenied()
        XCTAssertFalse(recovery.consumeRetryOnReturn())
        XCTAssertFalse(recovery.consumeRetryOnReturn())
    }

    func testDeniedActivationRetriesOncePerSettingsVisit() {
        var recovery = ScreenCapturePermissionRecovery()
        recovery.requestActivation()
        recovery.captureDenied()
        recovery.settingsBecameActive()
        XCTAssertTrue(recovery.consumeRetryOnReturn())
        XCTAssertFalse(recovery.consumeRetryOnReturn())
        recovery.requestActivation()
        recovery.captureDenied()
        XCTAssertFalse(recovery.consumeRetryOnReturn(), "A failed retry must not schedule another retry")
        recovery.settingsBecameActive()
        XCTAssertTrue(recovery.consumeRetryOnReturn())
    }

    func testSettingsOpenedByPermissionDialogCanPrecedeDenial() {
        var recovery = ScreenCapturePermissionRecovery()
        recovery.requestActivation()
        recovery.settingsBecameActive()
        XCTAssertFalse(recovery.consumeRetryOnReturn(), "Settings alone is not a denial")
        recovery.captureDenied()
        XCTAssertTrue(recovery.consumeRetryOnReturn())
    }

    func testSuccessAndUserCancellationPreventStaleRetries() {
        var recovery = ScreenCapturePermissionRecovery()
        recovery.requestActivation()
        recovery.captureDenied()
        recovery.settingsBecameActive()
        recovery.captureStarted()
        XCTAssertFalse(recovery.consumeRetryOnReturn())
        recovery.captureDenied()
        recovery.settingsBecameActive()
        recovery.cancel()
        XCTAssertFalse(recovery.consumeRetryOnReturn())
    }
}
