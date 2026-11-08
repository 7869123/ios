// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUtilityMedia",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AIUtilityMedia", targets: ["AIUtilityMedia"]),
        // P2 local tools (ImageIO / AVFoundation); other platforms throw unsupportedPlatform.
        .library(name: "AIUtilityMediaApple", targets: ["AIUtilityMediaApple"])
    ],
    targets: [
        .target(name: "AIUtilityMedia"),
        .target(name: "AIUtilityMediaApple", dependencies: ["AIUtilityMedia"]),
        .testTarget(name: "AIUtilityMediaTests", dependencies: ["AIUtilityMedia"]),
        .testTarget(name: "AIUtilityMediaAppleTests", dependencies: ["AIUtilityMediaApple", "AIUtilityMedia"])
    ],
    swiftLanguageModes: [.v6]
)
