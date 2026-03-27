// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AeroSpacePlugin",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AeroSpacePlugin", type: .dynamic, targets: ["AeroSpacePlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hytfjwr/StatusBarKit", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "AeroSpacePlugin",
            dependencies: [
                .product(name: "StatusBarKit", package: "StatusBarKit"),
            ]
        ),
    ]
)
