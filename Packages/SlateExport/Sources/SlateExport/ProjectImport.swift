import Foundation
import SlateCore

/// File › Import…: a Slate project folder or `.zip`, a screenplay, or a folder of Markdown notes.
public enum ProjectImport {
    public enum Kind: Equatable, Sendable {
        case slateFolder, zip, screenplay, markdownFolder
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case unsupported(String)
        case noProjectInZip
        case unzipFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let name): "Slate can't import “\(name)”. Choose a project folder or .zip, a screenplay, or a folder of Markdown notes."
            case .noProjectInZip: "The .zip doesn't contain a Slate project (a folder with project.json)."
            case .unzipFailed(let reason): "Couldn't unzip it: \(reason)"
            }
        }
    }

    public static let screenplayExtensions: Set<String> = ["fountain", "fdx", "txt", "md", "markdown"]

    /// What `url` is, judged by its contents.
    public static func kind(of url: URL) -> Kind? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue {
            if ProjectScanner.isProject(url) { return .slateFolder }
            return containsMarkdown(url) ? .markdownFolder : nil
        }
        let ext = url.pathExtension.lowercased()
        if ext == "zip" { return .zip }
        return screenplayExtensions.contains(ext) ? .screenplay : nil
    }

    static func containsMarkdown(_ folder: URL) -> Bool {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in items where ["md", "markdown"].contains(url.pathExtension.lowercased()) { return true }
        return false
    }

    /// Copies a project into `parent` as a separate project (its own ID), named after it.
    public static func copyProject(_ source: URL, into parent: URL) throws -> URL {
        let manifest = try ProjectManifest.decode(CoordinatedFileIO.read(source.appending(path: ProjectLayout.manifest)))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = ProjectFolders.freeFolder(for: manifest.name, in: parent)
        // Keep the name unless the folder needed a number (`Tidewater 2`); then use that.
        let renamed = target.lastPathComponent != ProjectCreator.folderName(for: manifest.name)
        try ProjectCreator.copySample(source, to: target, title: renamed ? target.lastPathComponent : manifest.name)
        return target
    }

    /// Unzips a project's `.zip` (with the system's `ditto`) and copies it into `parent`.
    public static func importZip(_ zip: URL, into parent: URL) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "SlateUnzip-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, staging.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ImportError.unzipFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // The project is the zip's root or a folder inside it.
        let candidates = [staging] + ((try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard let project = candidates.first(where: ProjectScanner.isProject) else { throw ImportError.noProjectInZip }
        return try copyProject(project, into: parent)
    }

    /// A folder of Markdown (an Obsidian vault, say) becomes a new project with
    /// its contents in `universe/`: subfolders, `[[links]]`, `.canvas` files and
    /// attachments kept; hidden folders such as `.obsidian` left out.
    public static func importMarkdownFolder(_ folder: URL, into parent: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let title = ProjectFolders.freeFolder(for: folder.lastPathComponent, in: parent).lastPathComponent
        let root = try ProjectCreator.create(title: title, template: .blank, in: parent)
        let universe = root.appending(path: "universe", directoryHint: .isDirectory)
        for item in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var target = universe.appending(path: item.lastPathComponent)
            // Don't overwrite the starter files: `draft.md` becomes `draft 2.md`.
            if fm.fileExists(atPath: target.path) {
                let stem = item.deletingPathExtension().lastPathComponent, ext = item.pathExtension
                var n = 2
                repeat {
                    target = universe.appending(path: "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
                    n += 1
                } while fm.fileExists(atPath: target.path)
            }
            try copySkippingHidden(item, to: target)
        }
        return root
    }

    private static func copySkippingHidden(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isFolder)
        guard isFolder.boolValue else {
            try fm.copyItem(at: source, to: target)
            return
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            try copySkippingHidden(item, to: target.appending(path: item.lastPathComponent))
        }
    }
}
