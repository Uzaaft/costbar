// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CostbarUsage",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CostbarUsage", targets: ["CostbarUsage"])],
    targets: [
        .target(name: "CostbarUsage", path: "macos/Sources/Costbar/MobileShared", exclude: ["UsageCloud.swift"]),
        .testTarget(name: "CostbarUsageTests", dependencies: ["CostbarUsage"], path: "mobile/Tests")
    ]
)
