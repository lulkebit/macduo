import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var angle: Double?
    @Published private(set) var sensorAvailable = false
    @Published private(set) var sensorMessage = "Looking for lid sensor…"
    @Published private(set) var isEnabled = false
    @Published private(set) var isStarting = false
    @Published private(set) var hasSnapshot = false
    @Published private(set) var snapshotCount = 0
    @Published private(set) var permissionNeeded = false
    @Published private(set) var message: String?
    @Published var previewAngle = 65.0
    @Published var previewFollowsLid = false
    @Published var previewShowsObserver = true
    @Published var startAngle: Double {
        didSet {
            UserDefaults.standard.set(startAngle, forKey: "startAngle")
            invalidateSnapshot()
            seedGateWithCurrentAngle()
        }
    }
    @Published var strength: Double {
        didSet { UserDefaults.standard.set(strength, forKey: "strength"); updateEffect() }
    }
    @Published var eyeHeight: Double {
        didSet { UserDefaults.standard.set(eyeHeight, forKey: "eyeHeight"); updateEffect() }
    }
    @Published var eyeDistance: Double {
        didSet { UserDefaults.standard.set(eyeDistance, forKey: "eyeDistance"); updateEffect() }
    }

    private enum SnapshotPurpose { case fold, permissionTest }
    private let sensor = LidAngleSensor()
    private let desktop = DesktopEffectController()
    private var gate = FoldSessionGate()
    private var foldSessionActive = false
    private var snapshotPurpose: SnapshotPurpose?
    private var smoothedAngle: Double?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var generation = 0
    private var activeGeneration: Int?
    // Keep cancelled tasks until they finish: the next task must await the
    // previous native screenshot, even if that API does not cancel immediately.
    private var snapshotTask: Task<Void, Never>?
    private var preparation: Task<Void, Error>?
    private var permissionRecovery = ScreenCapturePermissionRecovery()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var suspensions = CaptureSuspensions()
    private var suspended: Bool { suspensions.isSuspended }
    private var isShuttingDown = false

    init() {
        let defaults = UserDefaults.standard
        func setting(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
            guard defaults.object(forKey: key) != nil else { return fallback }
            let value = defaults.double(forKey: key)
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        startAngle = setting("startAngle", fallback: 100, range: 70...125)
        strength = setting("strength", fallback: 0.8, range: 0...1.4)
        eyeHeight = setting("eyeHeight", fallback: 1.5, range: 0.4...3)
        eyeDistance = setting("eyeDistance", fallback: 3, range: 1.5...5)

        sensor.onAngle = { [weak self] value in self?.receiveAngle(value) }
        sensor.onStatus = { [weak self] status in
            guard let self, !self.suspended, !self.isShuttingDown else { return }
            switch status {
            case .connected:
                self.sensorAvailable = true
                self.sensorMessage = "Lid sensor connected"
            case .unavailable(let reason):
                self.sensorAvailable = false
                self.sensorMessage = reason
                self.angle = nil
                self.invalidateSnapshot()
            }
        }
        desktop.onFailure = { [weak self] reason in
            guard let self, self.activeGeneration == self.generation,
                  !self.suspended, !self.isShuttingDown else { return }
            self.gate.captureFailed()
            self.invalidateSnapshot(resetGate: false)
            self.permissionRecovery.cancel()
            self.permissionNeeded = false
            self.message = reason
        }
        desktop.onFirstFrame = { [weak self] in
            guard let self, self.activeGeneration == self.generation,
                  !self.suspended, !self.isShuttingDown else { return }
            self.hasSnapshot = true
            self.snapshotCount += 1
        }
        sensor.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        installObservers()
    }

    var displayedAngle: Double { previewFollowsLid ? (angle ?? previewAngle) : previewAngle }
    var previewProgress: Double { FoldResponse.progress(angle: displayedAngle, startAngle: startAngle) }
    var previewProjection: FoldProjection.Configuration {
        FoldProjection.Configuration(angle: min(startAngle, displayedAngle), referenceAngle: startAngle,
                                     eyeHeight: eyeHeight, eyeDistance: eyeDistance)
    }
    var maxBlur: Double { 10 * strength }
    var glass: Double { 0.18 * strength }
    var statusText: String {
        if isStarting { return "Taking snapshot…" }
        if permissionNeeded { return "Screen recording access needed" }
        if hasSnapshot { return "Projecting a single snapshot" }
        if isEnabled && !sensorAvailable { return sensorMessage }
        if isEnabled { return "Ready when you fold" }
        return "Paused · no screen capture"
    }

    func setEnabled(_ enabled: Bool) {
        guard !isShuttingDown, enabled != isEnabled else { return }
        isEnabled = enabled
        permissionRecovery.cancel()
        invalidateSnapshot()
        if enabled {
            seedGateWithCurrentAngle()
            if !permissionNeeded { message = nil }
        }
        // Arming never requests permission, queries capture sources or takes a picture.
    }

    func testSingleSnapshot() {
        guard !isShuttingDown, !suspended, !isStarting else { return }
        isEnabled = true
        invalidateSnapshot()
        seedGateWithCurrentAngle()
        beginSnapshot(.permissionTest)
    }

    func retryScreenRecordingPermission() { testSingleSnapshot() }

    private func receiveAngle(_ value: Double) {
        guard !suspended, !isShuttingDown else { return }
        angle = value
        if smoothedAngle == nil { smoothedAngle = value }
        retryAfterSettingsIfPossible()
        guard isEnabled, sensorAvailable, snapshotPurpose != .permissionTest else { return }
        switch gate.update(angle: value, startAngle: startAngle) {
        case .none:
            break
        case .begin:
            foldSessionActive = true
            beginSnapshot(.fold)
        case .end:
            invalidateSnapshot(resetGate: false)
        }
    }

    private func beginSnapshot(_ purpose: SnapshotPurpose) {
        guard isEnabled, !isShuttingDown, !suspended, !isStarting else { return }
        generation += 1
        let request = generation
        snapshotPurpose = purpose
        isStarting = true
        hasSnapshot = false
        permissionRecovery.requestActivation()
        message = permissionNeeded ? "Checking snapshot access…" : nil
        let previous = snapshotTask
        snapshotTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, request == self.generation,
                  self.isEnabled, !self.suspended, !self.isShuttingDown else { return }
            self.activeGeneration = request
            let preparation = Task { @MainActor in try await self.desktop.prepare() }
            self.preparation = preparation
            do {
                try await preparation.value
                guard request == self.generation, !Task.isCancelled else { return }
                self.preparation = nil
                self.permissionRecovery.captureStarted()
                self.permissionNeeded = false
                self.isStarting = false
                if purpose == .permissionTest {
                    // The diagnostic image is never displayed or retained.
                    self.invalidateSnapshot()
                    self.seedGateWithCurrentAngle()
                    self.message = "Snapshot access works. Test image discarded; ready to fold."
                } else {
                    self.message = nil
                    self.updateEffect()
                }
            } catch {
                guard request == self.generation else { return }
                self.gate.captureFailed()
                self.invalidateSnapshot(resetGate: false)
                self.permissionNeeded = ScreenCapturePermission.isDenied(error)
                if self.permissionNeeded {
                    self.permissionRecovery.captureDenied()
                    self.message = ScreenCapturePermission.deniedMessage
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" {
                        self.permissionRecovery.settingsBecameActive()
                    }
                } else {
                    self.permissionRecovery.cancel()
                    self.message = error.localizedDescription
                }
                self.retryAfterSettingsIfPossible()
            }
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func retryAfterSettingsIfPossible() {
        guard NSApp.isActive, !isShuttingDown, !suspended, permissionNeeded, !isStarting,
              permissionRecovery.consumeRetryOnReturn() else { return }
        testSingleSnapshot()
    }

    func useCurrentAngle() {
        guard let angle else { return }
        startAngle = min(125, max(70, angle))
    }

    private func seedGateWithCurrentAngle() {
        if isEnabled, !suspended, sensorAvailable, let angle {
            _ = gate.update(angle: angle, startAngle: startAngle)
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTick
        lastTick = now
        guard isEnabled, !suspended, !isShuttingDown, sensorAvailable, let angle else { return }
        let current = smoothedAngle ?? angle
        let next = FoldResponse.smooth(current: current, target: angle, elapsed: elapsed)
        smoothedAngle = abs(next - angle) < 0.01 ? angle : next
        updateEffect()
    }

    private func updateEffect() {
        guard isEnabled, foldSessionActive, hasSnapshot, !isStarting,
              !suspended, !isShuttingDown, sensorAvailable, let smoothedAngle else { return }
        let physicalAngle = min(startAngle, smoothedAngle)
        desktop.setEffect(
            progress: FoldResponse.progress(angle: physicalAngle, startAngle: startAngle),
            maxBlur: maxBlur, glass: glass,
            projection: FoldProjection.Configuration(angle: physicalAngle, referenceAngle: startAngle,
                                                     eyeHeight: eyeHeight, eyeDistance: eyeDistance)
        )
    }

    private func invalidateSnapshot(resetGate: Bool = true) {
        generation += 1
        activeGeneration = nil
        preparation?.cancel()
        preparation = nil
        snapshotTask?.cancel()
        // Do not nil snapshotTask: its native request may still be finishing.
        desktop.discard()
        snapshotPurpose = nil
        isStarting = false
        hasSnapshot = false
        foldSessionActive = false
        smoothedAngle = angle
        if resetGate { gate.reset() }
    }

    private func suspend(_ reason: CaptureSuspensions.Reason) {
        guard !isShuttingDown, suspensions.suspend(reason) else { return }
        invalidateSnapshot()
        sensor.stop()
        angle = nil
        smoothedAngle = nil
        sensorAvailable = false
        sensorMessage = "Lid sensor paused"
    }

    private func resume(_ reason: CaptureSuspensions.Reason) {
        guard !isShuttingDown, suspensions.resume(reason) else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        sensorMessage = "Looking for lid sensor…"
        sensor.start()
        // The first post-wake measurement only establishes a new baseline.
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        isEnabled = false
        permissionRecovery.cancel()
        timer?.invalidate()
        timer = nil
        sensor.stop()
        invalidateSnapshot()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == "com.apple.systempreferences" else { return }
                self?.permissionRecovery.settingsBecameActive()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryAfterSettingsIfPossible() }
        })
        let workspaceEvents: [(Notification.Name, Notification.Name, CaptureSuspensions.Reason)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .systemSleep),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaySleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession)
        ]
        for (sleep, wake, reason) in workspaceEvents {
            workspaceObservers.append(workspace.addObserver(forName: sleep, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(reason) }
            })
            workspaceObservers.append(workspace.addObserver(forName: wake, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(reason) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suspended, !self.isShuttingDown else { return }
                self.invalidateSnapshot()
                self.seedGateWithCurrentAngle()
            }
        })
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(.screenLock) }
        })
        distributedObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume(.screenLock) }
        })
    }
}

/// Sleep, display power, session switching and locking have independent pairs
/// of notifications. Only the final matching resume makes capture eligible.
struct CaptureSuspensions {
    enum Reason: Hashable { case systemSleep, displaySleep, inactiveSession, screenLock }
    private var reasons: Set<Reason> = []
    var isSuspended: Bool { !reasons.isEmpty }

    mutating func suspend(_ reason: Reason) -> Bool {
        let wasSuspended = isSuspended
        reasons.insert(reason)
        return !wasSuspended
    }

    mutating func resume(_ reason: Reason) -> Bool {
        let wasSuspended = isSuspended
        reasons.remove(reason)
        return wasSuspended && !isSuspended
    }
}
