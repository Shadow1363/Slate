// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlateExport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SlateExport", targets: ["SlateExport"]),
    ],
    dependencies: [
        .package(path: "../SlateCore"),
    ],
    targets: [
        .target(
            name: "SlateExport",
            dependencies: ["SlateCore"],
            resources: [.copy("Resources/Fonts")]
        ),
        .testTarget(name: "SlateExportTests", dependencies: ["SlateExport", "SlateCore"]),
    ]
)
