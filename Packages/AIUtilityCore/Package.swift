// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUtilityCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "AIUtilityCore", targets: ["AIUtilityCore"])],
    targets: [
        .target(name: "AIUtilityCore"),
        .testTarget(name: "AIUtilityCoreTests", dependencies: ["AIUtilityCore"])
    ]
)
