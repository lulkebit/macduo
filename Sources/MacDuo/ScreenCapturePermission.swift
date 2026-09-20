import Foundation
import ScreenCaptureKit

enum ScreenCapturePermission {
    static let deniedMessage = "macOS could not use the screen recording permission. If MacDuo is already allowed, quit it, remove its old entry in System Settings, then add the current app from Applications. Reopen MacDuo and choose Retry access."

    /// A failed permission preflight is not authoritative for ScreenCaptureKit.
    /// Only its actual user-declined error means that access was denied.
    static func isDenied(_ error: Error) -> Bool {
        var current = error as NSError
        var visited = Set<ObjectIdentifier>()
        for _ in 0..<16 {
            guard visited.insert(ObjectIdentifier(current)).inserted else { return false }
            if current.domain == SCStreamErrorDomain,
               current.code == SCStreamError.Code.userDeclined.rawValue {
                return true
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }
}

/// A real denial blocks all sensor-triggered requests, independently of the
/// fold gate. Pausing, waking, reopening the lid and visiting Settings must not
/// dismiss the block. Only a successful explicit capture clears it.
struct ScreenCapturePermissionRecovery {
    private(set) var requiresExplicitRetry: Bool

    init(requiresExplicitRetry: Bool = false) {
        self.requiresExplicitRetry = requiresExplicitRetry
    }

    var allowsAutomaticCapture: Bool { !requiresExplicitRetry }

    mutating func captureSucceeded() {
        requiresExplicitRetry = false
    }

    mutating func captureDenied() {
        requiresExplicitRetry = true
    }
}
