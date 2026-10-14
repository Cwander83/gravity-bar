// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GravityBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "GravityBar",
            targets: ["GravityBar"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "GravityBar",
            dependencies: [],
            path: "Sources/GravityBar"
        )
    ]
)
