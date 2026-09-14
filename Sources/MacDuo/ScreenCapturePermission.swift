import Foundation
import ScreenCaptureKit

enum ScreenCapturePermission {
    static let deniedMessage = "Allow MacDuo in System Settings → Privacy & Security → Screen Recording, then return and test access again."

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

/// One retry per Settings visit, after an explicit activation and real denial.
/// Dismissing a permission dialog or repeatedly activating the app cannot loop.
struct ScreenCapturePermissionRecovery {
    private var userRequestedActivation = false
    private var awaitingPermission = false
    private var visitedSettings = false

    mutating func requestActivation() {
        userRequestedActivation = true
        awaitingPermission = false
        visitedSettings = false
    }

    mutating func captureStarted() {
        awaitingPermission = false
        visitedSettings = false
    }

    mutating func captureDenied() {
        awaitingPermission = userRequestedActivation
    }

    mutating func cancel() {
        userRequestedActivation = false
        awaitingPermission = false
        visitedSettings = false
    }

    mutating func settingsBecameActive() {
        // Apple's permission dialog may activate Settings before delivering
        // the denial. Remember that visit, but still require a real denial.
        if userRequestedActivation { visitedSettings = true }
    }

    mutating func consumeRetryOnReturn() -> Bool {
        guard userRequestedActivation, awaitingPermission, visitedSettings else { return false }
        visitedSettings = false
        return true
    }
}
