// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenUsage",
    platforms: [.macOS(.v14)],
    products: [.library(name: "UsageCore", targets: ["UsageCore"])],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "TokenUsage", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
