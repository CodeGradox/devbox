// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DevBox",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DevBox", targets: ["DevBox"]),
        .library(name: "DevBoxCore", targets: ["DevBoxCore"])
    ],
    targets: [
        .target(name: "DevBoxCore"),
        .executableTarget(name: "DevBox", dependencies: ["DevBoxCore"]),
        .testTarget(name: "DevBoxCoreTests", dependencies: ["DevBoxCore"]),
        .testTarget(name: "DevBoxTests", dependencies: ["DevBox", "DevBoxCore"])
    ]
)
