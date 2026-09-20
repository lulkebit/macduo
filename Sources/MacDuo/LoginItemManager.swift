import AppKit
import Carbon
import Combine
import ServiceManagement

@MainActor
protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemServicing {}

/// Service Management is the source of truth, including changes made in Settings.
/// Merely launching MacDuo never registers or re-enables the login item.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    let isApplicationBundle: Bool

    private let service: any LoginItemServicing

    init(
        service: any LoginItemServicing = SMAppService.mainApp,
        isApplicationBundle: Bool = Bundle.main.bundleURL.pathExtension == "app"
    ) {
        self.service = service
        self.isApplicationBundle = isApplicationBundle
        status = service.status
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    var statusMessage: String? {
        if !isApplicationBundle { return "Open the installed MacDuo.app to manage launch at login." }
        if let errorMessage { return errorMessage }
        switch status {
        case .notRegistered, .enabled:
            return nil
        case .requiresApproval:
            return "Allow MacDuo in Login Items to start automatically."
        case .notFound:
            return "macOS could not find this app as a login item. Try enabling it again."
        @unknown default:
            return "Login item status is unavailable."
        }
    }

    func refresh() {
        let current = service.status
        if status != current { errorMessage = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard isApplicationBundle else { return }

        // A registered service with revoked consent needs approval in Settings,
        // not another registration. It can still be removed explicitly.
        if enabled && (status == .enabled || status == .requiresApproval) { return }
        if !enabled && status == .notRegistered { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
            if enabled && status != .enabled && status != .requiresApproval {
                errorMessage = "Could not enable launch at login. Please try again."
            }
        } catch {
            refresh()
            // Registration can report denied consent while the service is
            // already registered. Show the actionable approval state instead.
            if !enabled || status != .requiresApproval {
                errorMessage = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum LaunchPresentation {
    static func shouldShowSettings(arguments: [String], event: NSAppleEventDescriptor?) -> Bool {
        if arguments.contains("--background") { return false }
        // macOS marks login launches in the open-application Apple event.
        // Do not infer this from registration status: explicit opens stay visible.
        let isLoginLaunch = event?.eventClass == kCoreEventClass
            && event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        return !isLoginLaunch
    }
}
