// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacDuo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacDuo", targets: ["MacDuo"])],
    targets: [
        .executableTarget(name: "MacDuo"),
        .testTarget(name: "MacDuoTests", dependencies: ["MacDuo"])
    ]
)
