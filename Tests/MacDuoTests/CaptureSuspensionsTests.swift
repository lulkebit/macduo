import XCTest
@testable import MacDuo

final class CaptureSuspensionsTests: XCTestCase {
    func testDisplayWakeCannotResumeASleepingLockedSession() {
        var state = CaptureSuspensions()
        XCTAssertTrue(state.suspend(.screenLock))
        XCTAssertFalse(state.suspend(.displaySleep))
        XCTAssertFalse(state.suspend(.systemSleep))
        XCTAssertFalse(state.resume(.displaySleep))
        XCTAssertTrue(state.isSuspended)
        XCTAssertFalse(state.resume(.systemSleep))
        XCTAssertTrue(state.isSuspended)
        XCTAssertTrue(state.resume(.screenLock))
        XCTAssertFalse(state.isSuspended)
    }

    func testUnlockCannotResumeInactiveUserSession() {
        var state = CaptureSuspensions()
        XCTAssertTrue(state.suspend(.inactiveSession))
        XCTAssertFalse(state.suspend(.screenLock))
        XCTAssertFalse(state.resume(.screenLock))
        XCTAssertTrue(state.isSuspended)
        XCTAssertTrue(state.resume(.inactiveSession))
        XCTAssertFalse(state.isSuspended)
    }

    func testDuplicateAndUnmatchedNotificationsDoNotRestartCapture() {
        var state = CaptureSuspensions()
        XCTAssertFalse(state.resume(.displaySleep))
        XCTAssertTrue(state.suspend(.systemSleep))
        XCTAssertFalse(state.suspend(.systemSleep))
        XCTAssertFalse(state.resume(.displaySleep))
        XCTAssertTrue(state.isSuspended)
        XCTAssertTrue(state.resume(.systemSleep))
        XCTAssertFalse(state.resume(.systemSleep))
        XCTAssertFalse(state.isSuspended)
        // A later independent sleep cycle must still work.
        XCTAssertTrue(state.suspend(.displaySleep))
        XCTAssertTrue(state.resume(.displaySleep))
    }
}
