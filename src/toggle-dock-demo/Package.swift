// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ToggleDockDemo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ToggleDockDemo", targets: ["ToggleDockDemo"])
    ],
    targets: [
        .executableTarget(name: "ToggleDockDemo")
    ]
)
