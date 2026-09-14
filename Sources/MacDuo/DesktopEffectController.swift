import AppKit
import CoreImage
import ScreenCaptureKit

enum DesktopEffectError: LocalizedError {
    case builtInDisplayUnavailable
    case builtInDisplayChanged
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .builtInDisplayUnavailable:
            return "No active built-in MacBook display found."
        case .builtInDisplayChanged:
            return "The built-in display changed. Enable the effect again."
        case .metalUnavailable:
            return "The glass effect requires an available Metal GPU."
        }
    }
}

/// Takes one RAM-only reference image when a fold session starts. Subsequent
/// hinge updates project that same image; there is no recording or capture loop.
@MainActor
final class DesktopEffectController {
    var onFailure: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?

    private var panel: GlassOverlayPanel?
    private var renderer: GlassMetalView?
    private var displayID: CGDirectDisplayID?
    private var capturedScreenFrame = CGRect.zero
    private var capturedPixelScale = 1.0
    private var generation: UInt64 = 0
    private var desiredProgress = 0.0
    private var desiredBlur = 40.0
    private var desiredGlass = 0.5
    private var desiredProjection: FoldProjection.Configuration?
    private var visibilityRequested = false
    private var hasFrame = false
    private var hasPresented = false

    func prepare() async throws {
        generation &+= 1
        let token = generation
        detach()

        do {
            try checkGeneration(token)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try checkGeneration(token)
            guard let display = content.displays.first(where: {
                CGDisplayIsBuiltin($0.displayID) != 0 && CGDisplayIsActive($0.displayID) != 0
            }), let screen = screen(for: display.displayID) else {
                throw DesktopEffectError.builtInDisplayUnavailable
            }
            let ownApps = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            // A background-only app may have no shareable windows/app entry.
            // An empty exclusion list is safe here: detach() removed the old
            // overlay, and the new one is created only after this single capture.

            let frame = screen.frame
            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            if #available(macOS 14.2, *) { filter.includeMenuBar = true }
            let configuration = makeScreenshotConfiguration(size: frame.size, scale: scale)

            // This is the only pixel capture in a session. SCScreenshotManager
            // returns a single image and requires no SCStream instance or timer.
            let snapshot = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
            try checkGeneration(token)
            guard displayStillMatches(display.displayID, frame: frame, scale: scale) else {
                throw DesktopEffectError.builtInDisplayChanged
            }

            let renderer = try GlassMetalView(
                frame: CGRect(origin: .zero, size: frame.size), pixelScale: scale
            )
            let panel = makePanel(frame: frame, renderer: renderer)
            self.panel = panel
            self.renderer = renderer
            self.displayID = display.displayID
            self.capturedScreenFrame = frame
            self.capturedPixelScale = scale
            renderer.onPresented = { [weak self] in
                guard let self, self.generation == token else { return }
                self.hasPresented = true
                self.updateVisibility()
            }
            renderer.onFailure = { [weak self] message in
                guard let self, self.generation == token else { return }
                self.fail(message)
            }

            // Only this current-generation renderer retains the reference image.
            // stop() clears it even if an older screenshot request is still pending.
            renderer.accept(image: CIImage(cgImage: snapshot))
            renderer.setEffect(
                progress: desiredProgress, maxBlur: desiredBlur,
                glass: desiredGlass, projection: desiredProjection
            )
            hasFrame = true
            onFirstFrame?()
            updateVisibility()
        } catch {
            // An older request must not tear down a newer session when it returns.
            if generation == token { detach() }
            throw error
        }
    }

    func setEffect(
        progress: Double,
        maxBlur: Double,
        glass: Double,
        projection: FoldProjection.Configuration? = nil
    ) {
        desiredProgress = progress.isFinite ? min(1, max(0, progress)) : 0
        desiredBlur = maxBlur.isFinite ? min(100, max(0, maxBlur)) : 0
        desiredGlass = glass.isFinite ? min(1, max(0, glass)) : 0
        desiredProjection = projection
        let newVisibility = desiredProgress > 0
        if visibilityRequested != newVisibility { hasPresented = false }
        visibilityRequested = newVisibility
        renderer?.setEffect(
            progress: desiredProgress, maxBlur: desiredBlur,
            glass: desiredGlass, projection: desiredProjection
        )
        updateVisibility()
    }

    func hide() {
        visibilityRequested = false
        hasPresented = false
        desiredProgress = 0
        renderer?.setEffect(
            progress: 0, maxBlur: desiredBlur,
            glass: desiredGlass, projection: desiredProjection
        )
        panel?.orderOut(nil)
    }

    func stop() async {
        discard()
    }

    func discard() {
        // Synchronous invalidation lets lock/sleep handlers release the image
        // immediately, without scheduling a task or waiting for native capture.
        generation &+= 1
        detach()
    }

    private func detach() {
        panel?.orderOut(nil)
        renderer?.onPresented = nil
        renderer?.onFailure = nil
        renderer?.clear()
        panel?.contentView = nil
        renderer = nil
        panel?.close()
        panel = nil
        displayID = nil
        capturedScreenFrame = .zero
        capturedPixelScale = 1
        visibilityRequested = false
        hasFrame = false
        hasPresented = false
        desiredProgress = 0
        desiredProjection = nil
    }

    private func checkGeneration(_ token: UInt64) throws {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private func displayStillMatches(_ id: CGDirectDisplayID, frame: CGRect, scale: Double) -> Bool {
        guard CGDisplayIsActive(id) != 0, CGDisplayIsBuiltin(id) != 0,
              let currentScreen = screen(for: id) else { return false }
        return currentScreen.frame == frame && currentScreen.backingScaleFactor == scale
    }

    private func updateVisibility() {
        guard visibilityRequested, desiredProgress > 0, hasFrame,
              let displayID, let panel else {
            panel?.orderOut(nil)
            return
        }
        guard displayStillMatches(displayID, frame: capturedScreenFrame, scale: capturedPixelScale) else {
            fail(DesktopEffectError.builtInDisplayChanged.localizedDescription)
            return
        }
        // A transparent panel lets Metal acquire a drawable. Reveal it only
        // after rendering the reference image, avoiding an empty initial frame.
        // The reference plane fully replaces the live desktop while folding.
        // A crossfade would expose an unprojected duplicate beneath this image.
        panel.alphaValue = hasPresented ? 1 : 0
        if !panel.isVisible {
            panel.orderFrontRegardless()
            renderer?.draw()
        }
    }

    private func fail(_ message: String) {
        generation &+= 1
        detach()
        onFailure?(message)
    }

    private func makeScreenshotConfiguration(size: CGSize, scale: Double) -> SCStreamConfiguration {
        // ScreenCaptureKit's macOS 14 screenshot API accepts this configuration
        // type; using it does not create or start a capture stream.
        let configuration = SCStreamConfiguration()
        configuration.width = Int((size.width * scale).rounded())
        configuration.height = Int((size.height * scale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.preservesAspectRatio = true
        return configuration
    }

    private func makePanel(frame: CGRect, renderer: GlassMetalView) -> GlassOverlayPanel {
        let panel = GlassOverlayPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = renderer
        panel.setFrame(frame, display: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.alphaValue = 0
        return panel
    }
}

private final class GlassOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
