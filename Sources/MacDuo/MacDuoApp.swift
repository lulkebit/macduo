import AppKit
import Carbon
import Combine
import SwiftUI

@main
enum MacDuoApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            runDiagnostics()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor private static func runDiagnostics() {
        print("MacDuo – local diagnostics")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("CoreGraphics preflight (advisory): \(CGPreflightScreenCaptureAccess() ? "passed" : "failed")")
        print("Enabling the effect does not capture the screen. Snapshot access can be tested separately.")
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displays, &count)
        print("Built-in display: \(displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 } ? "available" : "inactive")")
        let sensor = LidAngleSensor()
        var receivedAngle = false
        sensor.onAngle = { value in
            if !receivedAngle { print("Live lid angle: \(value)°") }
            receivedAngle = true
        }
        sensor.onStatus = { status in
            switch status {
            case .connected(let name): print("Sensor: \(name)")
            case .unavailable(let reason): print("Sensor: \(reason)")
            }
        }
        sensor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        sensor.stop()
        if !receivedAngle { print("No valid lid angle received.") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var toggleItem: NSMenuItem!
    private var angleItem: NSMenuItem!
    private var subscription: AnyCancellable?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "MacDuo") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "MacDuo – glass effect as you fold"
        let menu = NSMenu()
        menu.delegate = self
        angleItem = NSMenuItem(title: "Reading lid angle…", action: nil, keyEquivalent: "")
        menu.addItem(angleItem)
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "Enable Effect", action: #selector(toggleEffect), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let settingsItem = NSMenuItem(title: "Open MacDuo…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacDuo", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        installApplicationMenu()
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenu() }
        }
        installHotKey()
        if !CommandLine.arguments.contains("--background") { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }

    @objc private func showSettings() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = "MacDuo"
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.backgroundColor = .windowBackgroundColor
            newWindow.setContentSize(NSSize(width: 560, height: 620))
            // Only float over our own active effect, never over system permission UI.
            newWindow.level = model.hasSnapshot ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1) : .normal
            newWindow.hidesOnDeactivate = true
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleEffect() { model.setEnabled(!model.isEnabled) }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private func updateMenu() {
        angleItem.title = model.angle.map { "Lid angle: \(Int($0.rounded()))°" } ?? "Lid sensor unavailable"
        toggleItem.title = model.isEnabled ? "Pause Effect  ⌃⌥⌘D" : "Enable Effect  ⌃⌥⌘D"
        toggleItem.state = model.isEnabled ? .on : .off
        window?.level = model.hasSnapshot ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1) : .normal
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MacDuo")
        let settings = NSMenuItem(title: "Open MacDuo…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacDuo", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func installHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.toggleEffect() }
            return noErr
        }, 1, &eventType, context, &eventHandler)
        guard handlerStatus == noErr else {
            reportHotKeyFailure()
            return
        }
        let identifier = EventHotKeyID(signature: 0x4D44554F, id: 1)
        let keyStatus = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey | cmdKey), identifier, GetApplicationEventTarget(), 0, &hotKey)
        if keyStatus != noErr { reportHotKeyFailure() }
    }

    private func reportHotKeyFailure() {
        let alert = NSAlert()
        alert.messageText = "Keyboard shortcut unavailable"
        alert.informativeText = "Could not register ⌃⌥⌘D. You can pause the effect from the MacDuo menu bar icon."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
