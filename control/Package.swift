// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LSFGMetalControl",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "LSFGMetalControl", targets: ["LSFGMetalControl"])
    ],
    targets: [
        .executableTarget(
            name: "LSFGMetalControl",
            path: "Sources/LSFGMetalControl"
        )
    ]
)
