// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUtilityCapturePoC",
    platforms: [.iOS("27.0")],
    products: [.library(name: "AIUtilityCapturePoC", targets: ["AIUtilityCapturePoC"])],
    dependencies: [.package(path: "../../Packages/AIUtilityCore")],
    targets: [
        .target(name: "AIUtilityCapturePoC", dependencies: [.product(name: "AIUtilityCore", package: "AIUtilityCore")]),
        .testTarget(name: "AIUtilityCapturePoCTests", dependencies: ["AIUtilityCapturePoC"])
    ],
    swiftLanguageModes: [.v6]
)
