// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlateVoice",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SlateVoice", targets: ["SlateVoice"]),
    ],
    targets: [
        // whisper.cpp, built as a universal macOS framework (Metal + Accelerate).
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .target(name: "SlateVoice", dependencies: ["whisper"]),
        .testTarget(name: "SlateVoiceTests", dependencies: ["SlateVoice"]),
    ]
)
