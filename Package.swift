// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FalaMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FalaMac", targets: ["FalaMac"])],
    targets: [
        .target(name: "FalaCore"),
        .executableTarget(name: "FalaMac", dependencies: ["FalaCore"]),
        .testTarget(name: "FalaCoreTests", dependencies: ["FalaCore"])
    ],
    swiftLanguageModes: [.v5]
)
