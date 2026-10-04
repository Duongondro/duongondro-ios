// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DuongondroCore",
    platforms: [.iOS(.v16), .macOS(.v13), .watchOS(.v9)],
    products: [
        .library(name: "DuongondroCore", targets: ["DuongondroCore"]),
        .library(name: "DuongondroStore", targets: ["DuongondroStore"]),
        .library(name: "DuongondroCrypto", targets: ["DuongondroCrypto"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Pure logic, no dependencies: practices, day keys, sessions, streaks.
        .target(name: "DuongondroCore"),
        // End-to-end encryption in CryptoKit: the byte formats of docs/crypto.md.
        .target(name: "DuongondroCrypto"),
        // The local GRDB database, as in CodeShare.
        .target(
            name: "DuongondroStore",
            dependencies: ["DuongondroCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "DuongondroCoreTests",
            dependencies: ["DuongondroCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "DuongondroCryptoTests",
            dependencies: ["DuongondroCrypto"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "DuongondroStoreTests",
            dependencies: ["DuongondroStore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
