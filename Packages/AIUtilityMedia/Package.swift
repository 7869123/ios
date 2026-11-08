// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUtilityMedia",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AIUtilityMedia", targets: ["AIUtilityMedia"])],
    targets: [
        .target(name: "AIUtilityMedia"),
        .testTarget(name: "AIUtilityMediaTests", dependencies: ["AIUtilityMedia"])
    ],
    swiftLanguageModes: [.v6]
)
