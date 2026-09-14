import CoreGraphics
import CoreImage
import XCTest
@testable import MacDuo

/// These checks measure rendered images, rather than the Core Image graph.
final class GlassImageFilterTests: XCTestCase {
    private let size = 256
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false
    ])

    func testOpenDisplayPreservesEveryPixelAndImageBounds() {
        // An offset extent also catches an accidental origin reset or crop.
        let input = stripedImage().transformed(by: .init(translationX: 37, y: 19))
        let output = GlassImageFilter.render(
            input: input, extent: input.extent, progress: 0,
            maxBlur: 100, glass: 1, pixelScale: 4
        )
        XCTAssertEqual(output.extent, input.extent)
        XCTAssertLessThan(meanDifference(pixels(input), pixels(output)), 0.00001)
    }

    func testMovingTopEdgeLosesMoreContrastThanHingeEdge() {
        // Identical vertical bars at every y make the top/bottom comparison
        // independent of subject matter. Sample away from the image boundary.
        let input = stripedImage()
        let output = pixels(GlassImageFilter.render(
            input: input, extent: input.extent, progress: 1,
            maxBlur: 12, glass: 0
        ))
        // Bitmap readback is top-down, unlike Core Image's y-up coordinates.
        let topContrast = contrast(output, rows: 20..<52)
        let bottomContrast = contrast(output, rows: 204..<236)
        XCTAssertGreaterThan(bottomContrast, 0.04, "The hinge must retain visible structure")
        XCTAssertLessThan(topContrast, bottomContrast * 0.8,
                          "The moving edge should be visibly softer than the hinge")
        XCTAssertGreaterThan(meanDifference(pixels(input), output), 0.02,
                             "A folded screen must visibly differ from the sharp source")
    }

    func testBlurKeepsMarkerLocationsStationary() {
        let input = image { x, y in
            if hypot(Double(x - 70), Double(y - 65)) < 22 { return (225, 45, 45) }
            if hypot(Double(x - 184), Double(y - 188)) < 22 { return (40, 190, 225) }
            return (128, 128, 128)
        }
        let original = pixels(input)
        let filtered = pixels(GlassImageFilter.render(
            input: input, extent: input.extent, progress: 0.8,
            maxBlur: 12, glass: 0
        ))
        for redMarker in [true, false] {
            let before = centroid(original, redMarker: redMarker)
            let after = centroid(filtered, redMarker: redMarker)
            XCTAssertEqual(after.x, before.x, accuracy: 1.5)
            XCTAssertEqual(after.y, before.y, accuracy: 1.5,
                           "Changing focus must not translate or resize the desktop")
        }
    }

    func testOpaqueFlatContentHasNoDarkOrTransparentBlurBorders() {
        let input = image { _, _ in (167, 167, 167) }
        let expected = pixels(input)
        let actual = pixels(GlassImageFilter.render(
            input: input, extent: input.extent, progress: 1,
            maxBlur: 48, glass: 0, pixelScale: 2
        ))
        // Permit one 8-bit step from the filter's internal color conversion.
        XCTAssertLessThan(meanDifference(actual, expected), 0.005)
        let centerValue = actual[((size / 2) * size + size / 2) * 4]
        for y in [0, 1, size / 2, size - 2, size - 1] {
            for x in [0, 1, size / 2, size - 2, size - 1] {
                let offset = (y * size + x) * 4
                XCTAssertEqual(actual[offset], expected[offset], accuracy: 0.005)
                XCTAssertEqual(actual[offset], centerValue, accuracy: 0.003,
                               "Blur must not create a dark rim around opaque content")
                XCTAssertEqual(actual[offset + 3], 1, accuracy: 0.001)
            }
        }
    }

    func testCorruptAndOutOfRangeControlsStillRenderFiniteOpaqueImages() {
        let input = stripedImage()
        let combinations: [(Double, Double, Double, Double)] = [
            (.nan, 32, 0.4, 1), (.infinity, 32, 0.4, 1),
            (-100, 32, 0.4, 1), (1, .nan, .nan, .nan),
            (1, -.infinity, -100, -2),
            (100, 1_000, 100, 100), (1, .infinity, 0.4, .infinity)
        ]
        for (progress, blur, glass, scale) in combinations {
            let output = GlassImageFilter.render(
                input: input, extent: input.extent, progress: progress,
                maxBlur: blur, glass: glass, pixelScale: scale
            )
            XCTAssertEqual(output.extent, input.extent)
            let rendered = pixels(output)
            XCTAssertTrue(rendered.allSatisfy { $0.isFinite && $0 >= -0.001 && $0 <= 1.001 })
            XCTAssertTrue(stride(from: 3, to: rendered.count, by: 4).allSatisfy {
                abs(rendered[$0] - 1) < 0.001
            })
            if !progress.isFinite || progress <= 0 {
                XCTAssertLessThan(meanDifference(rendered, pixels(input)), 0.00001,
                                  "An invalid hinge signal must leave the screen clear")
            }
        }
    }

    private func stripedImage() -> CIImage {
        image { x, _ in x % 32 < 16 ? (225, 225, 225) : (30, 30, 30) }
    }

    private func image(_ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let value = color(x, y)
                let offset = (y * size + x) * 4
                bytes[offset] = value.0
                bytes[offset + 1] = value.1
                bytes[offset + 2] = value.2
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8, colorSpace: colorSpace)
    }

    private func pixels(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: .nan, count: size * size * 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!,
                           rowBytes: size * 4 * MemoryLayout<Float>.size,
                           bounds: image.extent, format: .RGBAf, colorSpace: colorSpace)
        }
        return values
    }

    private func meanDifference(_ first: [Float], _ second: [Float]) -> Double {
        zip(first, second).reduce(0) { $0 + Double(abs($1.0 - $1.1)) } / Double(first.count)
    }

    private func contrast(_ pixels: [Float], rows: Range<Int>) -> Double {
        let samples = rows.flatMap { y in
            (32..<(size - 32)).map { Double(pixels[(y * size + $0) * 4]) }
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        return sqrt(samples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(samples.count))
    }

    private func centroid(_ pixels: [Float], redMarker: Bool) -> CGPoint {
        var weight = 0.0, weightedX = 0.0, weightedY = 0.0
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * size + x) * 4
                let difference = Double(pixels[offset] - pixels[offset + 2])
                let signal = max(0, redMarker ? difference : -difference)
                weight += signal
                weightedX += Double(x) * signal
                weightedY += Double(y) * signal
            }
        }
        XCTAssertGreaterThan(weight, 1, "The marker must remain visible")
        return CGPoint(x: weightedX / max(1, weight), y: weightedY / max(1, weight))
    }
}
