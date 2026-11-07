// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUtilityAppleServices",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "AIUtilityAppleServices", targets: ["AIUtilityAppleServices"])],
    dependencies: [.package(path: "../AIUtilityCore")],
    targets: [
        .target(name: "AIUtilityAppleServices", dependencies: [.product(name: "AIUtilityCore", package: "AIUtilityCore")]),
        .testTarget(name: "AIUtilityAppleServicesTests", dependencies: ["AIUtilityAppleServices"])
    ]
)
