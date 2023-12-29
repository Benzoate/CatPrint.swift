// swift-tools-version:5.7

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
    dependencies: [
    ],
    targets: [
        .target(
            name: "CatPrint",
            dependencies: [
            ],
            path: "Sources"
        )
    ],
    swiftLanguageVersions: [.v5]
)
