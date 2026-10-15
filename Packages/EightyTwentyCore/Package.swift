// swift-tools-version: 6.0
import PackageDescription

// Pure Swift: Foundation only, no Apple-only frameworks.
// That keeps the scoring, parsing and backup logic testable on Linux (`swift test`).
let package = Package(
    name: "EightyTwentyCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "EightyTwentyCore", targets: ["EightyTwentyCore"]),
    ],
    targets: [
        .target(name: "EightyTwentyCore"),
        .testTarget(
            name: "EightyTwentyCoreTests",
            dependencies: ["EightyTwentyCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
