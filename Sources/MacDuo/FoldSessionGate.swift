import Foundation

/// Requests one snapshot for a physical fold session, never for an idle lid.
/// Seed this with the current angle on enable; reset it on disable/sleep/lock.
struct FoldSessionGate {
    enum Action: Equatable { case none, begin, end }

    private enum Phase { case idle, active, blockedAfterFailure }
    private static let minimumMovement = 2.0

    private var phase = Phase.idle
    private var baseline: Double?
    private var previousStartAngle: Double?

    mutating func update(angle: Double, startAngle: Double) -> Action {
        guard angle.isFinite, (0...180).contains(angle), startAngle.isFinite,
              startAngle > FoldResponse.closedAngle, startAngle <= 180 else {
            let needsEnd = phase == .active
            reset()
            return needsEnd ? .end : .none
        }

        let thresholdChanged = previousStartAngle != nil && previousStartAngle != startAngle
        previousStartAngle = startAngle

        guard let baseline else {
            self.baseline = angle
            return .none
        }

        // A settings change is not physical movement. Keep an existing session
        // if it still applies, or end it when the new threshold is exceeded.
        if thresholdChanged {
            self.baseline = angle
            if angle >= startAngle {
                let needsEnd = phase == .active
                phase = .idle
                return needsEnd ? .end : .none
            }
            return .none
        }

        switch phase {
        case .active:
            // Release the old image at the normal working position, so the
            // next closing gesture always starts with a fresh snapshot.
            guard angle >= startAngle else { return .none }
            phase = .idle
            self.baseline = angle
            return .end

        case .blockedAfterFailure:
            // A denied/failed snapshot must not retry on every sensor step.
            // Opening fully rearms it; an explicit retry can instead reset it.
            if angle >= startAngle {
                phase = .idle
                self.baseline = angle
            }
            return .none

        case .idle:
            if angle >= startAngle {
                self.baseline = angle
                return .none
            }
            // Put the noise margin on entry rather than retaining an old
            // snapshot beyond the reference angle. Straddling that angle with
            // small sensor fluctuations must not repeatedly start sessions.
            guard angle <= startAngle - Self.minimumMovement else { return .none }
            // Accumulate displacement from the baseline, not travelled path
            // length: sub-degree noise at rest must not add up to a capture.
            guard abs(angle - baseline) >= Self.minimumMovement else { return .none }
            phase = .active
            self.baseline = angle
            return .begin
        }
    }

    mutating func reset() {
        phase = .idle
        baseline = nil
        previousStartAngle = nil
    }

    mutating func captureFailed() {
        // Explicit one-image permission tests can fail while the fold gate is
        // idle. They need the same retry suppression as a failed fold snapshot.
        phase = .blockedAfterFailure
    }
}
