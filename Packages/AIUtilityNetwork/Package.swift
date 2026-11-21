// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUtilityNetwork",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // Speed test (Cloudflare) and IP / DNS / WebRTC leak checks. Pure logic builds and is tested on Linux;
        // URLSession metrics, UDP (Network.framework) and DNS-SD transports are Apple-only.
        .library(name: "AIUtilityNetwork", targets: ["AIUtilityNetwork"])
    ],
    targets: [
        .target(name: "AIUtilityNetwork"),
        .testTarget(name: "AIUtilityNetworkTests", dependencies: ["AIUtilityNetwork"])
    ],
    swiftLanguageModes: [.v6]
)
