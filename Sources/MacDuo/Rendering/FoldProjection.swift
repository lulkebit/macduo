import CoreGraphics
import Foundation

/// Perspective compensation for a fixed eye looking through a moving lid.
/// All physical distances use the display height as one unit. The hinge is x,
/// +y points toward the viewer along the keyboard, and +z points upward.
enum FoldProjection {
    struct Configuration: Equatable {
        var angle: Double
        var referenceAngle: Double
        var eyeHeight: Double
        var eyeDistance: Double

        init(angle: Double, referenceAngle: Double,
             eyeHeight: Double = 1.5, eyeDistance: Double = 3.0) {
            self.angle = angle
            self.referenceAngle = referenceAngle
            self.eyeHeight = eyeHeight
            self.eyeDistance = eyeDistance
        }
    }

    struct Corners: Equatable {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomRight: CGPoint
        let bottomLeft: CGPoint
    }

    /// Coordinates on the fixed reference image seen through a physical pixel.
    /// The result may lie outside the image: those rays see opaque matte instead.
    static func sourcePoint(forScreenPoint point: CGPoint, in extent: CGRect,
                            configuration: Configuration) -> CGPoint? {
        guard let geometry = Geometry(configuration), valid(extent),
              point.x.isFinite, point.y.isFinite else { return nil }
        let x = Double((point.x - extent.midX) / extent.height)
        let v = Double((point.y - extent.minY) / extent.height)
        // E + t(P-E) intersects the fixed reference plane at this t.
        let denominator = geometry.referenceFacing + v * geometry.sinDelta
        guard denominator > 0.0001 else { return nil }
        let sourceX = geometry.referenceFacing * x / denominator
        let sourceV = geometry.lidFacing * v / denominator
        return pointInExtent(x: sourceX, v: sourceV, extent: extent)
    }

    /// Where a fixed reference-image landmark must be drawn on the moving lid.
    /// This is the counterwarp, not a conventional rotation of the screenshot.
    static func screenPoint(forSourcePoint point: CGPoint, in extent: CGRect,
                            configuration: Configuration) -> CGPoint? {
        guard let geometry = Geometry(configuration), valid(extent),
              point.x.isFinite, point.y.isFinite else { return nil }
        let x = Double((point.x - extent.midX) / extent.height)
        let v = Double((point.y - extent.minY) / extent.height)
        let denominator = geometry.lidFacing - v * geometry.sinDelta
        guard denominator > 0.0001 else { return nil }
        let screenX = x * geometry.lidFacing / denominator
        let screenV = v * geometry.referenceFacing / denominator
        return pointInExtent(x: screenX, v: screenV, extent: extent)
    }

    /// Use this quad to show the physical lid in an observer-view preview.
    /// Warping the already counterwarped texture into it restores the original
    /// landmark positions inside the changing aperture of the physical screen.
    static func projectedLidCorners(in extent: CGRect,
                                    configuration: Configuration) -> Corners? {
        corners(in: extent) {
            sourcePoint(forScreenPoint: $0, in: extent, configuration: configuration)
        }
    }

    /// Destination quad for a CIPerspectiveTransform of the reference image.
    static func counterwarpedImageCorners(in extent: CGRect,
                                         configuration: Configuration) -> Corners? {
        corners(in: extent) {
            screenPoint(forSourcePoint: $0, in: extent, configuration: configuration)
        }
    }

    /// A face viewed edge-on contains no visible area. Fade before the singular
    /// angle instead of magnifying without limit or flipping the image over.
    static func visibility(configuration: Configuration) -> Double {
        guard let geometry = Geometry(configuration) else { return 0 }
        let facing = geometry.lidFacing / hypot(configuration.eyeDistance, configuration.eyeHeight)
        let t = min(1, max(0, (facing - 0.025) / 0.085))
        return t * t * (3 - 2 * t)
    }

    private struct Geometry {
        let referenceFacing: Double
        let lidFacing: Double
        let sinDelta: Double

        init?(_ configuration: Configuration) {
            let c = configuration
            guard c.angle.isFinite, c.referenceAngle.isFinite,
                  c.eyeDistance.isFinite, c.eyeHeight.isFinite,
                  (0...180).contains(c.angle), (0...180).contains(c.referenceAngle),
                  (0.1...20).contains(c.eyeDistance), (0.05...10).contains(c.eyeHeight)
            else { return nil }
            let angle = c.angle * .pi / 180
            let reference = c.referenceAngle * .pi / 180
            referenceFacing = c.eyeDistance * sin(reference) - c.eyeHeight * cos(reference)
            lidFacing = c.eyeDistance * sin(angle) - c.eyeHeight * cos(angle)
            sinDelta = sin(angle - reference)
            guard referenceFacing > 0.0001, lidFacing > 0.0001 else { return nil }
        }
    }

    private static func valid(_ extent: CGRect) -> Bool {
        extent.origin.x.isFinite && extent.origin.y.isFinite &&
        extent.width.isFinite && extent.height.isFinite &&
        extent.width > 0 && extent.height > 0
    }

    private static func pointInExtent(x: Double, v: Double, extent: CGRect) -> CGPoint? {
        // Limit the work submitted to Core Image near any projective horizon.
        // Rejecting the entire mapping is preferable to clamping its shape.
        guard x.isFinite, v.isFinite, abs(x) <= 16, abs(v) <= 16 else { return nil }
        let result = CGPoint(x: extent.midX + CGFloat(x) * extent.height,
                             y: extent.minY + CGFloat(v) * extent.height)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    private static func corners(in extent: CGRect,
                                mapping: (CGPoint) -> CGPoint?) -> Corners? {
        guard valid(extent),
              let tl = mapping(CGPoint(x: extent.minX, y: extent.maxY)),
              let tr = mapping(CGPoint(x: extent.maxX, y: extent.maxY)),
              let br = mapping(CGPoint(x: extent.maxX, y: extent.minY)),
              let bl = mapping(CGPoint(x: extent.minX, y: extent.minY)) else { return nil }
        return Corners(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }
}
