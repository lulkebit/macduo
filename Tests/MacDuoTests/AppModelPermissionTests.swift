import Combine
import ScreenCaptureKit
import XCTest
@testable import MacDuo

final class AppModelPermissionTests: XCTestCase {
    @MainActor
    func testPersistedDenialSurvivesRearmingAndRelaunch() {
        let suite = "MacDuoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "screenAccessRequiresRetry")
        defaults.set(true, forKey: "effectEnabled")
        let sensor = PermissionTestSensor()
        let desktop = PermissionTestDesktop()
        let model = AppModel(defaults: defaults, sensor: sensor, desktop: desktop)
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(model.permissionNeeded)
        XCTAssertNotNil(model.message)
        for _ in 0..<10 {
            model.setEnabled(false)
            model.setEnabled(true)
            model.startAngle = 100
            sensor.send(110)
            sensor.send(70)
        }
        XCTAssertEqual(desktop.requestCount, 0)
        XCTAssertFalse(model.isStarting)
        model.shutdown()
        XCTAssertTrue(defaults.bool(forKey: "effectEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "screenAccessRequiresRetry"))
        let restored = AppModel(defaults: defaults, sensor: PermissionTestSensor(), desktop: PermissionTestDesktop())
        XCTAssertTrue(restored.isEnabled)
        XCTAssertTrue(restored.permissionNeeded)
        restored.shutdown()
    }

    @MainActor
    func testLateDenialCancelsAnAlreadyQueuedFold() async {
        let suite = "MacDuoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sensor = PermissionTestSensor()
        let desktop = PermissionTestDesktop()
        let model = AppModel(defaults: defaults, sensor: sensor, desktop: desktop)
        defer { model.shutdown() }
        let started = expectation(description: "First native capture starts")
        desktop.onRequest = { started.fulfill() }
        model.setEnabled(true)
        sensor.send(110)
        sensor.send(80)
        await fulfillment(of: [started], timeout: 2)
        // Opening cancels the first request, closing queues the next one while
        // macOS is still completing the original permission request.
        sensor.send(110)
        sensor.send(80)
        let settled = expectation(description: "Queued capture is suppressed")
        let subscription = model.$isStarting.dropFirst().filter { !$0 }.prefix(1).sink { _ in settled.fulfill() }
        desktop.onRequest = { XCTFail("A stale denial must suppress the queued automatic capture") }
        desktop.finish(throwing: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
        await fulfillment(of: [settled], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertTrue(model.permissionNeeded)
        XCTAssertTrue(defaults.bool(forKey: "screenAccessRequiresRetry"))
        XCTAssertEqual(desktop.requestCount, 1)
        model.setEnabled(false)
        model.setEnabled(true)
        sensor.send(110)
        sensor.send(60)
        XCTAssertFalse(model.isStarting)
        XCTAssertEqual(desktop.requestCount, 1)
    }

    @MainActor
    func testExplicitRetryClearsPersistedBlockAndRequiresNewMovement() async {
        let suite = "MacDuoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "screenAccessRequiresRetry")
        let sensor = PermissionTestSensor()
        let desktop = PermissionTestDesktop()
        let model = AppModel(defaults: defaults, sensor: sensor, desktop: desktop)
        defer { model.shutdown() }
        sensor.send(80)
        let started = expectation(description: "Explicit capture starts")
        desktop.onRequest = { started.fulfill() }
        model.retryScreenRecordingPermission()
        model.retryScreenRecordingPermission() // Double clicks cannot queue another capture.
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.permissionNeeded)
        let finished = expectation(description: "Test capture finishes")
        let subscription = model.$isStarting.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        desktop.finish()
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertFalse(model.permissionNeeded)
        XCTAssertFalse(defaults.bool(forKey: "screenAccessRequiresRetry"))
        XCTAssertFalse(model.hasSnapshot)
        XCTAssertEqual(model.snapshotCount, 1)
        XCTAssertEqual(desktop.requestCount, 1)
        sensor.send(80)
        sensor.send(81)
        sensor.send(80)
        XCTAssertFalse(model.isStarting)
        XCTAssertEqual(desktop.requestCount, 1)
    }

    @MainActor
    func testLateSuccessAfterPausingDoesNotClearThePermissionBlock() async {
        let suite = "MacDuoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "screenAccessRequiresRetry")
        let desktop = PermissionTestDesktop()
        let model = AppModel(defaults: defaults, sensor: PermissionTestSensor(), desktop: desktop)
        defer { model.shutdown() }
        let started = expectation(description: "Explicit retry starts")
        desktop.onRequest = { started.fulfill() }
        model.retryScreenRecordingPermission()
        await fulfillment(of: [started], timeout: 2)

        model.setEnabled(false)
        let messageAfterPausing = model.message
        let delivered = expectation(description: "Cancelled native request delivers success")
        desktop.onResponse = { delivered.fulfill() }
        let staleUpdate = expectation(description: "Cancelled success must not update the model")
        staleUpdate.isInverted = true
        let subscription = model.objectWillChange.sink { _ in staleUpdate.fulfill() }
        // The native operation ignores cancellation and even delivers its frame
        // callback. Neither that callback nor its successful return may rearm us.
        desktop.finish()
        await fulfillment(of: [delivered], timeout: 2)
        await fulfillment(of: [staleUpdate], timeout: 0.1)
        withExtendedLifetime(subscription) {}

        XCTAssertTrue(model.permissionNeeded)
        XCTAssertTrue(defaults.bool(forKey: "screenAccessRequiresRetry"))
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "effectEnabled"))
        XCTAssertFalse(model.isStarting)
        XCTAssertFalse(model.hasSnapshot)
        XCTAssertEqual(model.snapshotCount, 0)
        XCTAssertEqual(desktop.requestCount, 1)
        XCTAssertEqual(model.message, messageAfterPausing)
    }
}

@MainActor
private final class PermissionTestSensor: LidAngleProviding {
    var onAngle: ((Double) -> Void)?
    var onStatus: ((LidAngleSensor.Status) -> Void)?
    func start() { onStatus?(.connected("Test sensor")) }
    func stop() {}
    func send(_ angle: Double) { onAngle?(angle) }
}

@MainActor
private final class PermissionTestDesktop: DesktopEffectProviding {
    var onFailure: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onRequest: (() -> Void)?
    var onResponse: (() -> Void)?
    private(set) var requestCount = 0
    private var completion: CheckedContinuation<Void, Error>?

    func prepare() async throws {
        requestCount += 1
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            onRequest?()
        }
        onFirstFrame?()
        onResponse?()
    }
    func finish(throwing error: Error? = nil) {
        let pending = completion
        completion = nil
        if let error { pending?.resume(throwing: error) }
        else { pending?.resume() }
    }
    func discard() {} // Native permission requests can outlive cancellation.
    func setEffect(progress: Double, maxBlur: Double, glass: Double, projection: FoldProjection.Configuration?) {}
}
