import Foundation

/// Whole-project file operations for the library: rename, duplicate, zip.
public enum ProjectFolders {
    /// A free folder for `title` in `parent`: `Title`, `Title 2`, `Title 3`…
    public static func freeFolder(for title: String, in parent: URL, except current: URL? = nil) -> URL {
        let base = ProjectCreator.folderName(for: title)
        var url = parent.appending(path: base, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path), url.standardizedFileURL != current?.standardizedFileURL {
            url = parent.appending(path: "\(base) \(n)", directoryHint: .isDirectory)
            n += 1
        }
        return url
    }

    /// Sets the project's name in `project.json` and renames its folder to match
    /// (adding ` 2` if that name is taken). Returns the folder's new location.
    @discardableResult
    public static func rename(_ root: URL, to name: String) throws -> URL {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return root }
        let manifestURL = root.appending(path: ProjectLayout.manifest)
        var manifest = try ProjectManifest.decode(CoordinatedFileIO.read(manifestURL))
        manifest.name = title
        try CoordinatedFileIO.write(try manifest.encoded(), to: manifestURL)
        let target = freeFolder(for: title, in: root.deletingLastPathComponent(), except: root)
        guard target.standardizedFileURL != root.standardizedFileURL else { return root }
        try FileManager.default.moveItem(at: root, to: target)
        return target
    }

    /// Copies a project beside itself as `<name> copy`, with its own ID, leaving out its cache and exports.
    @discardableResult
    public static func duplicate(_ root: URL) throws -> URL {
        let manifest = try ProjectManifest.decode(CoordinatedFileIO.read(root.appending(path: ProjectLayout.manifest)))
        let title = manifest.name + " copy"
        let target = freeFolder(for: title, in: root.deletingLastPathComponent())
        try ProjectCreator.copySample(root, to: target, title: title, skipping: [ProjectLayout.exports])
        return target
    }

    /// Writes a `.zip` of the project (its cache and exports left out) to `destination`.
    public static func zip(_ root: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "SlateZip-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        let copy = staging.appending(path: root.lastPathComponent, directoryHint: .isDirectory)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: root.path)
        where ![ProjectLayout.cache, ProjectLayout.exports, ".DS_Store"].contains(name) {
            try fm.copyItem(at: root.appending(path: name), to: copy.appending(path: name))
        }
        // Asking to read a folder "for uploading" makes the system zip it.
        var coordinatorError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: copy, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: zipped, to: destination)
            } catch {
                thrown = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let thrown { throw thrown }
    }
}
