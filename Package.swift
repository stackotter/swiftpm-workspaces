// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GitPackageRegistry",
    platforms: [
        .macOS(.v11)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor", from: "4.76.0"),
        .package(url: "https://github.com/mxcl/Version", from: "2.0.1"),
    ],
    targets: [
        .executableTarget(
            name: "GitPackageRegistry",
            dependencies: [
                .product(
                    name: "Vapor",
                    package: "vapor"
                ),
                "Version",
            ]
        ),
    ]
)
