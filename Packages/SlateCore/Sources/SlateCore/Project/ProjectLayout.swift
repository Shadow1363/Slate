import Foundation

/// Fixed names inside a project folder (see "Project folder format" in SPEC.md).
public enum ProjectLayout {
    public static let manifest = "project.json"
    public static let universe = "universe"
    /// The rough draft.
    public static let draft = "universe/draft.md"
    public static let script = "script"
    public static let storyboard = "storyboard"
    public static let dictionary = "dictionary"
    public static let templates = "templates"
    public static let exports = "exports"
    /// Index, caches and window state. Always safe to delete.
    public static let cache = ".slate"
    public static let backups = ".slate/backups"

    /// File extensions the app treats as editable plain text.
    public static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "fountain", "json", "canvas", "slatetheme", "csv",
    ]

    public static func isTextFile(_ path: String) -> Bool {
        textExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

/// The four areas of a project window, each backed by one top-level folder.
public enum ProjectArea: String, CaseIterable, Sendable, Identifiable, Codable {
    case universe
    case script
    case storyboard
    case dictionary

    public var id: String { rawValue }

    public var folder: String { rawValue }

    public var title: String {
        switch self {
        case .universe: "Universe"
        case .script: "Script"
        case .storyboard: "Storyboard"
        case .dictionary: "Dictionary"
        }
    }

    /// Cmd-1 … Cmd-4.
    public var shortcutNumber: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}

/// A file inside one of the four area folders.
public struct ProjectFile: Identifiable, Hashable, Sendable {
    /// Path relative to the project root, e.g. `script/01-act-one.md`.
    public let relativePath: String
    public let area: ProjectArea

    public var id: String { relativePath }

    /// Path relative to the area folder, e.g. `01-act-one.md` or `margin/todos.md`.
    public var pathInArea: String {
        String(relativePath.dropFirst(area.folder.count + 1))
    }

    public var name: String { (relativePath as NSString).lastPathComponent }

    public var isText: Bool { ProjectLayout.isTextFile(relativePath) }

    public init(relativePath: String, area: ProjectArea) {
        self.relativePath = relativePath
        self.area = area
    }
}

/// Resolves symlinks the way FSEvents reports paths (`/var` → `/private/var`).
/// `URL.resolvingSymlinksInPath()` strips `/private`, so it can't be used here.
func canonicalPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    if let resolved = realpath(path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }
    // The item may not exist (e.g. it was just deleted): resolve its parent.
    guard path != "/" else { return path }
    let parentPath = canonicalPath(url.deletingLastPathComponent())
    return (parentPath as NSString).appendingPathComponent(url.lastPathComponent)
}
