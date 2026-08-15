// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CatPrint",
    platforms: [.iOS(.v16),
                .macOS(.v13),
                .tvOS(.v16)],
    products: [
        .library(
            name: "CatPrint",
            targets: ["CatPrint"]
        ),
    ],
    targets: [
        .target(
            name: "CatPrint",
            path: "Sources"
        )
    ]
)
