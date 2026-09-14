import AppKit
import CoreImage
import MetalKit

@MainActor
final class GlassMetalView: MTKView, MTKViewDelegate {
    var onPresented: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let imageContext: CIContext
    private let commandQueue: MTLCommandQueue
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let rendersIdentity: Bool
    private var sourceImage: CIImage?
    private var progress = 0.0
    private var maximumBlur = 0.0
    private var glass = 0.0
    private var projection: FoldProjection.Configuration?
    private var pixelScale = 1.0
    private var renderGeneration: UInt64 = 0
    private var isRendering = false
    private var needsAnotherFrame = false

    init(frame: CGRect, pixelScale: Double, rendersIdentity: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw DesktopEffectError.metalUnavailable
        }
        self.commandQueue = queue
        self.imageContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        self.pixelScale = pixelScale
        self.rendersIdentity = rendersIdentity
        super.init(frame: frame, device: device)
        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = false
        self.autoResizeDrawable = true
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.clearColor = MTLClearColorMake(0, 0, 0, 0)
        self.layer?.isOpaque = false
        (self.layer as? CAMetalLayer)?.colorspace = outputColorSpace
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func accept(_ buffer: CVPixelBuffer) {
        sourceImage = CIImage(cvPixelBuffer: buffer)
        requestDraw()
    }

    /// A preview can reuse its static image while sharing the live rendering path.
    func accept(image: CIImage) {
        guard sourceImage !== image else { return }
        sourceImage = image
        requestDraw()
    }

    func setEffect(progress: Double, maxBlur: Double, glass: Double,
                   projection: FoldProjection.Configuration? = nil) {
        guard self.progress != progress || maximumBlur != maxBlur || self.glass != glass ||
                self.projection != projection else { return }
        if (self.progress > 0) != (progress > 0) {
            // A completion from before hide must never reveal an older image.
            renderGeneration &+= 1
        }
        self.progress = progress
        self.maximumBlur = maxBlur
        self.glass = glass
        self.projection = projection
        requestDraw()
    }

    func clear() {
        renderGeneration &+= 1
        sourceImage = nil
        needsAnotherFrame = false
        imageContext.clearCaches()
    }

    func requestDraw() {
        guard progress > 0 || rendersIdentity, sourceImage != nil else { return }
        if isRendering {
            needsAnotherFrame = true
        } else {
            needsDisplay = true
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        requestDraw()
    }

    func draw(in view: MTKView) {
        guard progress > 0 || rendersIdentity, let sourceImage, !isRendering,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let outputExtent = CGRect(origin: .zero, size: drawableSize)
        guard outputExtent.width > 0, outputExtent.height > 0 else { return }

        // Convert the frozen reference image to backing pixels before its
        // perspective compensation is calculated in display-height units.
        let image = sourceImage.transformed(by: CGAffineTransform(
            scaleX: outputExtent.width / sourceImage.extent.width,
            y: outputExtent.height / sourceImage.extent.height
        ))
        let filtered = GlassImageFilter.render(
            input: image, extent: outputExtent, progress: progress,
            maxBlur: maximumBlur, glass: glass, pixelScale: pixelScale, projection: projection
        )
        isRendering = true
        let token = renderGeneration
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commandBuffer)
        // Core Image's y-axis points upward; Metal presents texture row zero at
        // the top. Explicit flipping keeps the captured desktop upright.
        destination.isFlipped = true
        destination.colorSpace = outputColorSpace
        do {
            _ = try imageContext.startTask(toRender: filtered, to: destination)
        } catch {
            isRendering = false
            onFailure?("Could not render the glass effect: \(error.localizedDescription)")
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let failure = buffer.status == .error ? (buffer.error?.localizedDescription ?? "Unknown GPU error") : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRendering = false
                guard self.renderGeneration == token else {
                    self.requestDraw()
                    return
                }
                if let failure {
                    self.onFailure?("Metal could not display the glass effect: \(failure)")
                } else {
                    self.onPresented?()
                }
                if self.needsAnotherFrame {
                    self.needsAnotherFrame = false
                    self.requestDraw()
                }
            }
        }
        commandBuffer.commit()
    }
}
