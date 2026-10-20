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
        // Seattle-area trails and researched routes for the run map (tools/routes builds it).
        .target(name: "EightyTwentyCore", resources: [.copy("Routes/seattle-routes.json")]),
        .testTarget(
            name: "EightyTwentyCoreTests",
            dependencies: ["EightyTwentyCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
