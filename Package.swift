// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-gmessages",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
        .tvOS(.v16)
    ],
    products: [
        // Core Google Messages client library
        .library(name: "LibGM", targets: ["LibGM"]),
        // CLI tool for testing
        .executable(name: "gmcli", targets: ["gmcli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Generated protobuf code
        .target(
            name: "GMProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/GMProto"
        ),

        // Cryptography layer
        .target(
            name: "GMCrypto",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/GMCrypto"
        ),

        // Core Google Messages client library
        .target(
            name: "LibGM",
            dependencies: [
                "GMProto",
                "GMCrypto",
            ],
            path: "Sources/LibGM"
        ),

        // CLI tool
        .executableTarget(
            name: "gmcli",
            dependencies: [
                "LibGM",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/gmcli"
        ),

        // Tests
        .testTarget(
            name: "GMCryptoTests",
            dependencies: ["GMCrypto"],
            path: "Tests/GMCryptoTests"
        ),
        .testTarget(
            name: "LibGMTests",
            dependencies: ["LibGM"],
            path: "Tests/LibGMTests"
        ),
    ]
)
