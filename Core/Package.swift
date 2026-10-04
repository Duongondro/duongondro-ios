// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DuongondroCore",
    platforms: [.iOS(.v16), .macOS(.v13), .watchOS(.v9)],
    products: [
        .library(name: "DuongondroCore", targets: ["DuongondroCore"]),
    ],
    targets: [
        .target(name: "DuongondroCore"),
        .testTarget(
            name: "DuongondroCoreTests",
            dependencies: ["DuongondroCore"],
            resources: [.copy("Resources")]
        ),
    ]
)
