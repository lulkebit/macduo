import AppKit
import Carbon
import ServiceManagement
import XCTest
@testable import MacDuo

final class LoginItemManagerTests: XCTestCase {
    @MainActor
    func testStartupAndRefreshNeverRegisterAndReflectSystemChanges() {
        let service = StubLoginItemService()
        let manager = LoginItemManager(service: service, isApplicationBundle: true)
        XCTAssertFalse(manager.isEnabled)

        service.status = .enabled
        manager.refresh()
        XCTAssertTrue(manager.isEnabled)

        service.status = .requiresApproval
        manager.refresh()
        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.requiresApproval)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    @MainActor
    func testExplicitToggleRegistersAndUnregistersWithoutRepeatingCalls() {
        let service = StubLoginItemService()
        let manager = LoginItemManager(service: service, isApplicationBundle: true)
        manager.setEnabled(true)
        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(service.registerCount, 1)

        manager.setEnabled(false)
        manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    @MainActor
    func testRegistrationFailureDoesNotShowEnabledAndCanBeRetried() {
        let service = StubLoginItemService()
        service.registrationError = NSError(domain: "LoginItemTest", code: 1)
        let manager = LoginItemManager(service: service, isApplicationBundle: true)
        manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertNotNil(manager.errorMessage)

        service.registrationError = nil
        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testRevokedConsentIsNotSilentlyRegisteredAgainAndCanBeRemoved() {
        let service = StubLoginItemService()
        service.status = .requiresApproval
        let manager = LoginItemManager(service: service, isApplicationBundle: true)
        manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.requiresApproval)
        XCTAssertEqual(service.registerCount, 0)

        manager.setEnabled(false)
        XCTAssertEqual(manager.status, .notRegistered)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    @MainActor
    func testRegistrationRequiringApprovalShowsActionableStatusEvenWhenAPIThrows() {
        let service = StubLoginItemService()
        service.statusAfterRegistration = .requiresApproval
        service.registrationError = NSError(domain: "LoginItemTest", code: 3)
        let manager = LoginItemManager(service: service, isApplicationBundle: true)
        manager.setEnabled(true)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.requiresApproval)
        XCTAssertNil(manager.errorMessage)
        XCTAssertNotNil(manager.statusMessage)
    }

    @MainActor
    func testUnregisterFailureKeepsRealEnabledStateVisible() {
        let service = StubLoginItemService()
        service.status = .enabled
        service.unregistrationError = NSError(domain: "LoginItemTest", code: 2)
        let manager = LoginItemManager(service: service, isApplicationBundle: true)
        manager.setEnabled(false)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertNotNil(manager.errorMessage)
    }

    @MainActor
    func testCommandLineBinaryCannotRegisterAsLoginItem() {
        let service = StubLoginItemService()
        let manager = LoginItemManager(service: service, isApplicationBundle: false)
        manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertNotNil(manager.statusMessage)
        XCTAssertEqual(service.registerCount, 0)
    }

    func testLoginLaunchIsQuietWhileExplicitLaunchesRemainVisible() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        XCTAssertTrue(LaunchPresentation.shouldShowSettings(arguments: [], event: event))
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        XCTAssertFalse(LaunchPresentation.shouldShowSettings(arguments: [], event: event))
        XCTAssertTrue(LaunchPresentation.shouldShowSettings(arguments: [], event: nil))
        XCTAssertFalse(LaunchPresentation.shouldShowSettings(arguments: ["--background"], event: nil))
    }
}

@MainActor
private final class StubLoginItemService: LoginItemServicing {
    var status: SMAppService.Status = .notRegistered
    var registerCount = 0
    var unregisterCount = 0
    var registrationError: Error?
    var unregistrationError: Error?
    var statusAfterRegistration: SMAppService.Status?

    func register() throws {
        registerCount += 1
        if let statusAfterRegistration { status = statusAfterRegistration }
        if let registrationError { throw registrationError }
        status = statusAfterRegistration ?? .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
}
