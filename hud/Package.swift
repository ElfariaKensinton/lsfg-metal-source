// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LSFGMetalHUD",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "LSFGMetalHUD", targets: ["LSFGMetalHUD"])
    ],
    targets: [
        .executableTarget(
            name: "LSFGMetalHUD",
            path: "Sources/LSFGMetalHUD"
        )
    ]
)
