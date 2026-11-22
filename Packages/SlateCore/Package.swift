// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlateCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SlateCore", targets: ["SlateCore"]),
    ],
    targets: [
        .target(
            name: "SlateCore",
            resources: [.copy("Resources/Themes")]
        ),
        .testTarget(
            name: "SlateCoreTests",
            dependencies: ["SlateCore"]
        ),
    ]
)
