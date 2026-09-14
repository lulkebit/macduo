import CoreGraphics
import CoreImage
import simd
import XCTest
@testable import MacDuo

final class FoldProjectionTests: XCTestCase {
    private let extent = CGRect(x: 31, y: 17, width: 512, height: 320)

    func testReferenceAngleIsIdentityAndEveryHingePointIsInvariant() throws {
        let identity = FoldProjection.Configuration(angle: 100, referenceAngle: 100)
        for x in stride(from: extent.minX, through: extent.maxX, by: 64) {
            for y in stride(from: extent.minY, through: extent.maxY, by: 40) {
                let point = CGPoint(x: x, y: y)
                assertPoint(try XCTUnwrap(FoldProjection.sourcePoint(
                    forScreenPoint: point, in: extent, configuration: identity)), equals: point)
            }
            for angle in [100.0, 65, 40, 30] {
                let c = FoldProjection.Configuration(angle: angle, referenceAngle: 100)
                let hinge = CGPoint(x: x, y: extent.minY)
                assertPoint(try XCTUnwrap(FoldProjection.screenPoint(
                    forSourcePoint: hinge, in: extent, configuration: c)), equals: hinge)
            }
        }
    }

    func testCounterwarpedLandmarksStayOnTheOriginalEyeRays() throws {
        // Construct physical points and normals in 3D independently of the
        // production homography. Eye→reference and eye→lid must be collinear.
        for angle in [80.0, 65, 40] {
            let c = FoldProjection.Configuration(angle: angle, referenceAngle: 100)
            let eye = SIMD3<Double>(0, c.eyeDistance, c.eyeHeight)
            for horizontal in [-0.35, 0.0, 0.35] {
                for vertical in [0.05, 0.15, 0.25] {
                    let referencePixel = CGPoint(x: extent.midX + horizontal * extent.height,
                                                 y: extent.minY + vertical * extent.height)
                    let lidPixel = try XCTUnwrap(FoldProjection.screenPoint(
                        forSourcePoint: referencePixel, in: extent, configuration: c))
                    let referenceWorld = world(referencePixel, angle: c.referenceAngle)
                    let lidWorld = world(lidPixel, angle: c.angle)
                    let referenceRay = simd_normalize(referenceWorld - eye)
                    let lidRay = simd_normalize(lidWorld - eye)
                    XCTAssertLessThan(simd_length(simd_cross(referenceRay, lidRay)), 0.00000001)
                    XCTAssertGreaterThan(simd_dot(referenceRay, lidRay), 0.99999999)
                    // A non-hinge landmark must actually move on the LCD.
                    XCTAssertGreaterThan(abs(lidPixel.y - referencePixel.y), 0.1)
                }
            }
        }
    }

    func testSamplingAndObserverQuadMatchIndependentRayPlaneIntersections() throws {
        for angle in [65.0, 40, 30] {
            let c = FoldProjection.Configuration(angle: angle, referenceAngle: 100)
            let eye = SIMD3<Double>(0, c.eyeDistance, c.eyeHeight)
            let referenceUp = up(c.referenceAngle)
            let normal = simd_cross(SIMD3<Double>(1, 0, 0), referenceUp)
            for vertical in [0.0, 0.3, 0.7, 1.0] {
                let pixel = CGPoint(x: extent.minX + extent.width * 0.23,
                                    y: extent.minY + extent.height * vertical)
                let ray = world(pixel, angle: c.angle) - eye
                let intersection = eye + ray * (-simd_dot(normal, eye) / simd_dot(normal, ray))
                let expected = CGPoint(x: extent.midX + intersection.x * extent.height,
                                       y: extent.minY + simd_dot(intersection, referenceUp) * extent.height)
                assertPoint(try XCTUnwrap(FoldProjection.sourcePoint(
                    forScreenPoint: pixel, in: extent, configuration: c)), equals: expected)
            }
            let quad = try XCTUnwrap(FoldProjection.projectedLidCorners(in: extent, configuration: c))
            XCTAssertLessThan(quad.topLeft.y, extent.maxY)
            XCTAssertGreaterThan(quad.topLeft.y, extent.minY)
            assertPoint(quad.bottomLeft, equals: CGPoint(x: extent.minX, y: extent.minY))
            assertPoint(quad.bottomRight, equals: CGPoint(x: extent.maxX, y: extent.minY))
        }
    }

    func testProductionImageActuallyUsesTheCounterwarp() throws {
        let input = coordinateImage()
        for angle in [65.0, 40] {
            let c = FoldProjection.Configuration(angle: angle, referenceAngle: 100)
            let output = GlassImageFilter.render(input: input, extent: extent, progress: 0.5,
                maxBlur: 0, glass: 0, projection: c)
            let eye = SIMD3<Double>(0, c.eyeDistance, c.eyeHeight)
            let lidUp = up(c.angle)
            let normal = simd_cross(SIMD3<Double>(1, 0, 0), lidUp)
            for horizontal in [-0.25, 0.15] {
                let referencePixel = CGPoint(x: extent.midX + horizontal * extent.height,
                                             y: extent.minY + 0.22 * extent.height)
                let ray = world(referencePixel, angle: c.referenceAngle) - eye
                let physical = eye + ray * (-simd_dot(normal, eye) / simd_dot(normal, ray))
                let lidPixel = CGPoint(x: extent.midX + physical.x * extent.height,
                                       y: extent.minY + simd_dot(physical, lidUp) * extent.height)
                XCTAssertTrue(extent.contains(lidPixel))
                let expected = sample(input, at: referencePixel)
                let actual = sample(output, at: lidPixel)
                for channel in 0..<4 {
                    XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.015,
                        "A ray through the tilted LCD must show the same reference pixel")
                }
                XCTAssertGreaterThan(abs(sample(output, at: referencePixel)[1] - expected[1]), 0.02,
                    "Merely keeping the screenshot in LCD coordinates is not compensation")
            }
        }
    }

    func testOutOfImageRaysAndBackFacingLidAreOpaqueMatte() {
        let white = CIImage(color: .white).cropped(to: extent)
        let c = FoldProjection.Configuration(angle: 40, referenceAngle: 100)
        let output = GlassImageFilter.render(input: white, extent: extent, progress: 0.5,
            maxBlur: 0, glass: 0, projection: c)
        let outside = sample(output, at: CGPoint(x: extent.minX + 2, y: extent.midY))
        XCTAssertLessThan(outside[0], 0.3, "Out-of-image rays must not stretch the screenshot edge")
        XCTAssertEqual(outside[3], 1, accuracy: 0.001, "The live desktop must not leak through")
        XCTAssertGreaterThan(sample(output, at: CGPoint(x: extent.midX, y: extent.midY))[0], 0.95)

        for angle in [26.0, 12, 0, Double.nan, Double.infinity] {
            let invalid = FoldProjection.Configuration(angle: angle, referenceAngle: 100)
            XCTAssertEqual(FoldProjection.visibility(configuration: invalid), 0)
            XCTAssertNil(FoldProjection.projectedLidCorners(in: extent, configuration: invalid))
            let hidden = GlassImageFilter.render(input: white, extent: extent, progress: 1,
                maxBlur: 0, glass: 0, projection: invalid)
            let pixel = sample(hidden, at: CGPoint(x: extent.midX, y: extent.midY))
            XCTAssertTrue(pixel.allSatisfy { $0.isFinite })
            XCTAssertLessThan(pixel[0], 0.3)
            XCTAssertEqual(pixel[3], 1, accuracy: 0.001)
        }
        XCTAssertLessThan(FoldProjection.visibility(configuration: .init(angle: 29, referenceAngle: 100)), 0.5)
        XCTAssertEqual(FoldProjection.visibility(configuration: .init(angle: 40, referenceAngle: 100)), 1)
    }

    private func up(_ angle: Double) -> SIMD3<Double> {
        let radians = angle * .pi / 180
        return SIMD3<Double>(0, cos(radians), sin(radians))
    }

    private func world(_ point: CGPoint, angle: Double) -> SIMD3<Double> {
        SIMD3<Double>(Double((point.x - extent.midX) / extent.height), 0, 0) +
            up(angle) * Double((point.y - extent.minY) / extent.height)
    }

    private func assertPoint(_ actual: CGPoint, equals expected: CGPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, file: file, line: line)
    }

    private func coordinateImage() -> CIImage {
        let width = Int(extent.width), height = Int(extent.height)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(255 * x / (width - 1))
                bytes[offset + 1] = UInt8(255 * (height - 1 - y) / (height - 1))
                bytes[offset + 2] = 64
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4,
                       size: extent.size, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            .transformed(by: .init(translationX: extent.minX, y: extent.minY))
    }

    private func sample(_ image: CIImage, at point: CGPoint) -> [Float] {
        var pixel = [Float](repeating: .nan, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            CIContext().render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1),
                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return pixel
    }
}
