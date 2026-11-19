// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MCPServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MCPServer", targets: ["MCPServer"])
    ],
    dependencies: [
        // Already in the app's dependency graph (MongoKitten, Citadel).
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0")
    ],
    targets: [
        .target(
            name: "MCPServer",
            dependencies: [
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "MCPServerTests",
            dependencies: ["MCPServer"]
        ),
    ]
)
