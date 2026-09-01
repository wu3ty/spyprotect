// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SpyProtect",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SpyProtect",
            path: "Sources/SpyProtect"
        )
    ]
)
