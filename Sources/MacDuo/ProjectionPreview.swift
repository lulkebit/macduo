import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Uses the actual LCD counterwarp, then projects that LCD into the same fixed
/// observer plane. The pale reference makes spatial anchoring inspectable.
@MainActor
struct ProjectionPreview: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let configuration: FoldProjection.Configuration
    let progress: Double
    let strength: Double
    let observerView: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 500, height: proposal.height ?? 277)
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = context.coordinator.render(configuration: configuration, progress: progress,
                                                strength: strength, observerView: observerView,
                                                darkAppearance: colorScheme == .dark)
    }

    @MainActor final class Coordinator {
        private let context = CIContext(options: [.cacheIntermediates: false])
        private let source: CIImage
        private let original: NSImage
        private var previous: FoldProjection.Configuration?
        private var previousProgress = -1.0
        private var previousStrength = -1.0
        private var previousObserver = false
        private var previousDarkAppearance = false
        private var cached: NSImage?

        init() {
            let renderer = ImageRenderer(content: DemoDesktopArtwork().frame(width: 460, height: 218).environment(\.colorScheme, .light))
            renderer.scale = 2
            if let image = renderer.cgImage {
                source = CIImage(cgImage: image)
                original = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            } else {
                source = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 920, height: 436))
                original = NSImage(size: NSSize(width: 920, height: 436))
            }
        }

        func render(configuration: FoldProjection.Configuration, progress: Double,
                    strength: Double, observerView: Bool, darkAppearance: Bool) -> NSImage? {
            if previous == configuration, previousProgress == progress,
               previousStrength == strength, previousObserver == observerView,
               previousDarkAppearance == darkAppearance { return cached }
            previous = configuration
            previousProgress = progress
            previousStrength = strength
            previousObserver = observerView
            previousDarkAppearance = darkAppearance

            let extent = source.extent
            let canvas = CGRect(x: 0, y: 0, width: 920, height: 430)
            let reference = CGRect(x: 110, y: 48, width: 700, height: 700 * extent.height / extent.width)
            let scale = reference.width / extent.width
            let placement = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: reference.minX, ty: reference.minY)
            let projected = GlassImageFilter.render(input: source, extent: extent, progress: progress,
                                                    maxBlur: 2.2 * strength, glass: 0.18 * strength,
                                                    pixelScale: 2, projection: configuration)
            let output: CIImage?
            let corners: FoldProjection.Corners?
            if observerView {
                corners = FoldProjection.projectedLidCorners(in: extent, configuration: configuration)
                if let corners {
                    let forward = CIFilter.perspectiveTransform()
                    forward.inputImage = projected
                    forward.topLeft = corners.topLeft
                    forward.topRight = corners.topRight
                    forward.bottomRight = corners.bottomRight
                    forward.bottomLeft = corners.bottomLeft
                    output = forward.outputImage?.transformed(by: placement)
                } else { output = nil }
            } else {
                corners = FoldProjection.Corners(topLeft: CGPoint(x: extent.minX, y: extent.maxY),
                                                 topRight: CGPoint(x: extent.maxX, y: extent.maxY),
                                                 bottomRight: CGPoint(x: extent.maxX, y: extent.minY),
                                                 bottomLeft: CGPoint(x: extent.minX, y: extent.minY))
                output = projected.transformed(by: placement)
            }

            let image = NSImage(size: canvas.size)
            image.lockFocus()
            if observerView {
                original.draw(in: reference, from: .zero, operation: .sourceOver, fraction: 0.12)
                let outline = NSBezierPath(rect: reference)
                outline.lineWidth = 1
                outline.setLineDash([5, 5], count: 2, phase: 0)
                NSColor(white: darkAppearance ? 1 : 0, alpha: darkAppearance ? 0.3 : 0.18).setStroke()
                outline.stroke()
            }
            if let output {
                let clear = CIImage(color: .clear).cropped(to: canvas)
                if let cgImage = context.createCGImage(output.composited(over: clear).cropped(to: canvas), from: canvas) {
                    NSImage(cgImage: cgImage, size: canvas.size).draw(in: canvas)
                }
            }
            if let corners {
                let frame = NSBezierPath()
                frame.move(to: corners.bottomLeft.applying(placement))
                frame.line(to: corners.topLeft.applying(placement))
                frame.line(to: corners.topRight.applying(placement))
                frame.line(to: corners.bottomRight.applying(placement))
                frame.close()
                frame.lineWidth = 8
                frame.lineJoinStyle = .round
                NSColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1).setStroke()
                frame.stroke()
            }
            // The hinge itself never moves in either representation.
            let hinge = NSBezierPath()
            hinge.move(to: CGPoint(x: reference.minX - 10, y: reference.minY - 6))
            hinge.line(to: CGPoint(x: reference.maxX + 10, y: reference.minY - 6))
            hinge.lineWidth = 7
            hinge.lineCapStyle = .round
            NSColor(white: 0.55, alpha: 1).setStroke()
            hinge.stroke()
            image.unlockFocus()
            cached = image
            return image
        }
    }
}
