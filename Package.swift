// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CDRip",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CDRip", targets: ["CDRipApp"])],
    targets: [
        .target(name: "CDRipCore"),
        .executableTarget(name: "CDRipApp", dependencies: ["CDRipCore"]),
        .testTarget(name: "CDRipCoreTests", dependencies: ["CDRipCore"])
    ]
)
