import Foundation

/// The physical hinge drives a reversible curve; time never drives the effect.
enum FoldResponse {
    static let closedAngle = 8.0

    static func progress(angle: Double, startAngle: Double = 100) -> Double {
        guard angle.isFinite, startAngle.isFinite, startAngle > closedAngle else { return 0 }
        let t = min(1, max(0, (startAngle - angle) / (startAngle - closedAngle)))
        return t * t * (3 - 2 * t)
    }

    static func smooth(current: Double, target: Double, elapsed: Double) -> Double {
        guard target.isFinite else { return current.isFinite ? current : 0 }
        guard current.isFinite else { return target }
        let dt = min(0.1, max(0, elapsed))
        // 35 ms removes one-degree sensor steps without a trailing canned animation.
        return current + (target - current) * (1 - exp(-dt / 0.035))
    }
}
