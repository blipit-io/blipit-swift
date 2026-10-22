// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlipitSwift",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "BlipitSwift", targets: ["BlipitSwift"]),
    ],
    targets: [
        .target(name: "BlipitNuggets"),
        .target(name: "BlipitSwift", dependencies: ["BlipitNuggets"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "BlipitSwiftTests", dependencies: ["BlipitSwift", "BlipitNuggets"]),
    ]
)
