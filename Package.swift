// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Outputly",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Outputly", targets: ["OutputlyApp"])],
    targets: [
        .target(name: "OutputlyCore"),
        .executableTarget(name: "OutputlyApp", dependencies: ["OutputlyCore"]),
        .testTarget(name: "OutputlyCoreTests", dependencies: ["OutputlyCore"]),
        .testTarget(name: "OutputlyAppTests", dependencies: ["OutputlyApp"]),
    ]
)
