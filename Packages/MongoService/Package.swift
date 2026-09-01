// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MongoService",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MongoService", targets: ["MongoService"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.16.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(path: "../ExtendedJSON"),
    ],
    targets: [
        .target(
            name: "MongoService",
            dependencies: [
                .product(name: "MongoKitten", package: "MongoKitten"),
                .product(name: "Logging", package: "swift-log"),
                "ExtendedJSON",
            ]
        ),
        .testTarget(
            name: "MongoServiceTests",
            dependencies: ["MongoService"]
        ),
    ]
)
