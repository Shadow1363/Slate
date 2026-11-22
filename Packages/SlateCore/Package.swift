// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlateCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SlateCore", targets: ["SlateCore"]),
    ],
    dependencies: [
        // Approved by the project owner for Milestone 4 (DECISIONS.md).
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "SlateCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [.copy("Resources/Themes"), .copy("Resources/Templates")]
        ),
        .testTarget(
            name: "SlateCoreTests",
            dependencies: ["SlateCore"]
        ),
    ]
)
