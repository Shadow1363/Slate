import Foundation

public enum ProjectCreationError: Error, Equatable, LocalizedError {
    case emptyTitle
    case folderNotEmpty(String)
    case sampleMissing

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "Give the project a title."
        case .folderNotEmpty(let path): "A folder already exists at \(path) and isn't empty. Pick another title or location."
        case .sampleMissing: "The showcase project isn't inside this copy of Slate."
        }
    }
}

public enum ProjectCreator {
    /// A Finder-safe folder name for a title: slashes and colons become dashes,
    /// and a leading dot is dropped so the folder isn't hidden.
    public static func folderName(for title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(200)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }

    /// The showcase project inside the app (`Tidewater` in its resources), if present.
    public static var bundledShowcase: URL? {
        Bundle.main.url(forResource: "Tidewater", withExtension: nil)
    }

    /// Creates `<parent>/<title>/` with the template's folders and starter files.
    /// The showcase template copies `sample` (the app's bundled Tidewater by default).
    /// Returns the new project folder.
    @discardableResult
    public static func create(
        title: String,
        template: ProjectTemplate,
        in parent: URL,
        date: Date = .now,
        sample: URL? = ProjectCreator.bundledShowcase
    ) throws -> URL {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectCreationError.emptyTitle }

        let fm = FileManager.default
        let root = parent.appending(path: folderName(for: trimmed), directoryHint: .isDirectory)
        if fm.fileExists(atPath: root.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            if contents.contains(where: { $0 != ".DS_Store" }) {
                throw ProjectCreationError.folderNotEmpty(root.path)
            }
        }
        if template == .showcase {
            guard let sample, fm.fileExists(atPath: sample.appending(path: ProjectLayout.manifest).path) else {
                throw ProjectCreationError.sampleMissing
            }
            try copySample(sample, to: root, title: trimmed)
            return root
        }

        for folder in template.folders {
            try fm.createDirectory(at: root.appending(path: folder, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        for (path, contents) in template.starterFiles(title: trimmed, date: date) {
            try CoordinatedFileIO.writeText(contents, to: root.appending(path: path))
        }
        let manifest = ProjectManifest(name: trimmed)
        try CoordinatedFileIO.write(try manifest.encoded(), to: root.appending(path: ProjectLayout.manifest))
        return root
    }

    /// Copies a sample project (without its `.slate/` cache), then gives the
    /// copy its own name and ID so it's a separate project in the library.
    static func copySample(_ source: URL, to root: URL, title: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where name != ProjectLayout.cache && name != ".DS_Store" {
            let target = root.appending(path: name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source.appending(path: name), to: target)
        }
        try fm.createDirectory(at: root.appending(path: ProjectLayout.cache, directoryHint: .isDirectory), withIntermediateDirectories: true)
        let manifestURL = root.appending(path: ProjectLayout.manifest)
        var manifest = try ProjectManifest.decode(Data(contentsOf: manifestURL))
        manifest.name = title
        manifest.id = ProjectManifest.newID()
        try CoordinatedFileIO.write(try manifest.encoded(), to: manifestURL)
    }
}

/// What a project card shows on the home screen.
public struct ProjectSummary: Sendable, Equatable {
    public var name: String
    public var lastEdited: Date?
    /// Open to-dos in `script/margin/todos.md`.
    public var openTodos = 0
    /// The first storyboard image, in script order, for the Home card.
    public var cover: URL?

    /// Reads `project.json` and finds the newest file modification date,
    /// skipping `.slate/` and `exports/`. Safe to call off the main thread.
    public static func load(at root: URL) -> ProjectSummary? {
        guard let data = try? CoordinatedFileIO.read(root.appending(path: ProjectLayout.manifest)),
              let manifest = try? ProjectManifest.decode(data)
        else { return nil }

        var newest: Date?
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == ProjectLayout.exports, url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let date = values.contentModificationDate else { continue }
                if newest == nil || date > newest! { newest = date }
            }
        }
        let open = Reminders.todos(in: root).filter { !$0.done }.count
        return ProjectSummary(name: manifest.name, lastEdited: newest, openTodos: open, cover: StoryboardCover.firstImage(in: root))
    }
}

public enum ProjectScanner {
    /// Folders directly inside `folder` that contain a `project.json`.
    public static func projects(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return children
            .filter { fm.fileExists(atPath: $0.appending(path: ProjectLayout.manifest).path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func isProject(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: ProjectLayout.manifest).path)
    }
}
