// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SSHTunnel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SSHTunnel", targets: ["SSHTunnel"]),
        .executable(name: "sshtestserver", targets: ["sshtestserver"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        // Kept in lockstep with Citadel's own dependencies (same fork/URLs)
        // so the modules resolve to a single package each.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(
            name: "SSHTunnel",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "SSHTunnelTests",
            dependencies: ["SSHTunnel"]
        ),
        .executableTarget(
            name: "sshtestserver",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIO", package: "swift-nio"),
            ]
        ),
    ]
)
