// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlipitSwift",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "BlipitSwift", targets: ["BlipitSwift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0"),
    ],
    targets: [
        .target(name: "BlipitSwift", dependencies: [.product(name: "Sentry", package: "sentry-cocoa")]),
        .testTarget(name: "BlipitSwiftTests", dependencies: ["BlipitSwift"]),
    ]
)
