// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlateUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SlateUI", targets: ["SlateUI"]),
    ],
    dependencies: [
        .package(path: "../SlateCore"),
    ],
    targets: [
        .target(name: "SlateUI", dependencies: ["SlateCore"]),
    ]
)
