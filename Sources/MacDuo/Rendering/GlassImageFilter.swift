import CoreImage
import CoreImage.CIFilterBuiltins

/// The snapshot overlay and deterministic visual checks use the same image graph.
/// The optional counterwarp anchors the image in the reference plane while the
/// physical screen moves. The hinge is the image's bottom edge.
enum GlassImageFilter {
    static func render(
        input: CIImage,
        extent: CGRect,
        progress: Double,
        maxBlur: Double,
        glass: Double,
        pixelScale: Double = 1,
        projection: FoldProjection.Configuration? = nil
    ) -> CIImage {
        let amount = progress.isFinite ? min(1, max(0, progress)) : 0
        let source = projectedImage(input, extent: extent, configuration: projection)
        guard amount > 0 else { return source }
        let blur = maxBlur.isFinite ? min(100, max(0, maxBlur)) : 0
        let material = glass.isFinite ? min(1, max(0, glass)) : 0
        let scale = pixelScale.isFinite ? min(4, max(1, pixelScale)) : 1

        // The moving edge loses focus first. A small amount remains at the hinge,
        // matching the frosted moving pane without moving or resizing its content.
        let mask = CIFilter.linearGradient()
        mask.point0 = CGPoint(x: extent.midX, y: extent.minY)
        mask.point1 = CGPoint(x: extent.midX, y: extent.maxY)
        let hingeBlur: CGFloat = projection == nil ? 0.35 : 0
        mask.color0 = CIColor(red: hingeBlur, green: hingeBlur, blue: hingeBlur)
        mask.color1 = CIColor(red: 1, green: 1, blue: 1)

        let variableBlur = CIFilter.maskedVariableBlur()
        variableBlur.inputImage = source.clampedToExtent()
        variableBlur.mask = mask.outputImage?.cropped(to: extent)
        variableBlur.radius = Float(blur * amount * scale)
        var result = (variableBlur.outputImage ?? source.clampedToExtent().applyingFilter(
            "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * amount * scale]
        )).cropped(to: extent)

        // A restrained neutral veil makes the blur read as translucent glass.
        let veil = CIImage(color: CIColor(
            red: 0.91, green: 0.94, blue: 0.97, alpha: amount * material * 0.32
        )).cropped(to: extent)
        result = veil.composited(over: result)

        let hingeLight = CIFilter.linearGradient()
        hingeLight.point0 = CGPoint(x: extent.midX, y: extent.minY)
        hingeLight.point1 = CGPoint(x: extent.midX, y: extent.minY + extent.height * 0.32)
        hingeLight.color0 = CIColor(
            red: 0.82, green: 0.91, blue: 1, alpha: amount * material * 0.09
        )
        hingeLight.color1 = CIColor(red: 0.82, green: 0.91, blue: 1, alpha: 0)
        if let light = hingeLight.outputImage {
            result = light.cropped(to: extent).composited(over: result)
        }
        return result.cropped(to: extent)
    }

    private static func projectedImage(_ input: CIImage, extent: CGRect,
                                       configuration: FoldProjection.Configuration?) -> CIImage {
        let source = input.cropped(to: extent)
        guard let configuration else { return source }
        let matte = CIImage(color: CIColor(red: 0.13, green: 0.16, blue: 0.18, alpha: 1))
            .cropped(to: extent)
        let visibility = FoldProjection.visibility(configuration: configuration)
        guard visibility > 0,
              let corners = FoldProjection.counterwarpedImageCorners(in: extent, configuration: configuration)
        else { return matte }
        if configuration.angle == configuration.referenceAngle { return source }

        let transform = CIFilter.perspectiveTransform()
        transform.inputImage = source
        transform.topLeft = corners.topLeft
        transform.topRight = corners.topRight
        transform.bottomRight = corners.bottomRight
        transform.bottomLeft = corners.bottomLeft
        guard var warped = transform.outputImage?.cropped(to: extent) else { return matte }
        if visibility < 1 {
            warped = warped.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: visibility)
            ])
        }
        // Rays outside the finite captured plane must never reveal the actual
        // desktop underneath or smear its edge pixels into unbounded streaks.
        return warped.composited(over: matte).cropped(to: extent)
    }
}
