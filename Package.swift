// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GitPackageRegistry",
    platforms: [
        .macOS(.v10_15)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor", from: "4.76.0"),
    ],
    targets: [
        .executableTarget(
            name: "GitPackageRegistry",
            dependencies: [
                .product(
                    name: "Vapor",
                    package: "vapor"
                ),
            ]
        ),
    ]
)
