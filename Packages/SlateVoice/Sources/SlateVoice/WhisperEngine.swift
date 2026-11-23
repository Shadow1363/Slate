import CryptoKit
import Foundation

/// The optional Whisper engine (whisper.cpp as a framework). Slate doesn't
/// ship it: Settings › Voice downloads it from a GitHub release, checks it
/// against the SHA-256 below, and unpacks it into Application Support.
public enum WhisperEngine {
    /// Bump with a new `whisper-<n>` release (Scripts/publish-whisper.sh prints these).
    public static let version = 1
    static let sha256 = "329f7a0a9929f4e1e44f2ce983ec4fe45f6c9ca5234a8695003282291e1bed40"
    public static let sizeDescription = "4 MB"

    static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "SlateUpdateRepository") as? String ?? "Shadow1363/Slate"
    }

    public static var downloadURL: URL {
        URL(string: "https://github.com/\(repository)/releases/download/whisper-\(version)/whisper-framework-\(version).zip")!
    }

    /// `~/Library/Application Support/Slate/Whisper/whisper.framework`.
    public static var frameworkURL: URL { WhisperModel.folder.appending(path: "whisper.framework", directoryHint: .isDirectory) }

    static var binaryURL: URL { frameworkURL.appending(path: "Versions/A/whisper") }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: binaryURL.path)
            && (try? String(contentsOf: versionFile, encoding: .utf8)) == String(version)
    }

    private static var versionFile: URL { WhisperModel.folder.appending(path: "engine-version") }

    /// Checks and unpacks a downloaded zip into place.
    static func install(zip: URL) throws {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else {
            throw VoiceError.whisperFailed("the download didn't match the expected file. Try again later.")
        }
        let fileManager = FileManager.default
        let staging = WhisperModel.folder.appending(path: "engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        let unpacked = staging.appending(path: "whisper.framework", directoryHint: .isDirectory)
        guard ditto.terminationStatus == 0, fileManager.fileExists(atPath: unpacked.appending(path: "Versions/A/whisper").path) else {
            throw VoiceError.whisperFailed("the download couldn't be unpacked.")
        }
        try? fileManager.removeItem(at: frameworkURL)
        try fileManager.moveItem(at: unpacked, to: frameworkURL)
        // Downloaded by Slate itself, so normally not quarantined; make sure.
        removexattr(binaryURL.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        try String(version).write(to: versionFile, atomically: true, encoding: .utf8)
    }

    /// Removes the engine (models stay). Takes effect for loading after Slate restarts.
    public static func uninstall() {
        try? FileManager.default.removeItem(at: frameworkURL)
        try? FileManager.default.removeItem(at: versionFile)
    }
}
