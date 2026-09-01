// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ExtendedJSON",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExtendedJSON", targets: ["ExtendedJSON"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/BSON.git", from: "8.2.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "ExtendedJSON",
            dependencies: [
                .product(name: "BSON", package: "BSON"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "ExtendedJSONTests",
            dependencies: ["ExtendedJSON"],
            resources: [
                .copy("Corpus")
            ]
        ),
    ]
)
