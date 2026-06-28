// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "OnRampSDK",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "OnRamp", targets: ["OnRamp"]),
    ],
    targets: [
        .target(name: "OnRamp", path: "Sources/OnRamp"),
        .testTarget(name: "OnRampTests", dependencies: ["OnRamp"], path: "Tests/OnRampTests"),
    ]
)
