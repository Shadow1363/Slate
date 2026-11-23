// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlateVoice",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SlateVoice", targets: ["SlateVoice"]),
    ],
    targets: [
        // whisper.cpp isn't linked: the user downloads it from Settings › Voice
        // and CWhisper opens it at run time. Vendor/whisper.xcframework is the
        // source of that download (Scripts/publish-whisper.sh) and of its headers.
        .target(name: "CWhisper"),
        .target(name: "SlateVoice", dependencies: ["CWhisper"]),
        .testTarget(name: "SlateVoiceTests", dependencies: ["SlateVoice"]),
    ]
)
