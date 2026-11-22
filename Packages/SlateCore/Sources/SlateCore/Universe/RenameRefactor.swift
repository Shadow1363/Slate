import Foundation

/// A text replacement in one project file.
public struct FileEdit: Sendable, Equatable, Identifiable {
    public let path: String
    /// UTF-16 range in the file.
    public let range: NSRange
    /// The text expected at `range`; the edit is skipped if it changed.
    public let original: String
    public let replacement: String
    /// The whole line, for previews.
    public let context: String

    public var id: String { "\(path)@\(range.location)" }

    public init(path: String, range: NSRange, original: String, replacement: String, context: String = "") {
        self.path = path
        self.range = range
        self.original = original
        self.replacement = replacement
        self.context = context
    }

    /// Applies edits to one file's text, last first so ranges stay valid.
    /// Returns nil if any edit's original text isn't where it should be.
    public static func apply(_ edits: [FileEdit], to text: String) -> String? {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(edit.range) <= result.length,
                  result.substring(with: edit.range) == edit.original else { return nil }
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}

/// Renaming a note and updating every `[[link]]` to it.
public enum RenameRefactor {
    public struct Plan: Sendable, Equatable {
        public let notePath: String
        public let oldName: String
        public let newName: String
        /// Link edits, by file then position. Links written with an alias are
        /// left alone: the alias still resolves.
        public let edits: [FileEdit]
        /// The note's new file, or nil when the slug doesn't change.
        public let newPath: String?

        public var fileCount: Int { Set(edits.map(\.path)).count }
    }

    public static func plan(renaming notePath: String, to newName: String, in graph: LinkGraph, existingPaths: Set<String>) -> Plan? {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note = graph.note(at: notePath), !newName.isEmpty else { return nil }
        var edits: [FileEdit] = []
        for path in graph.files.keys.sorted() {
            for source in graph.files[path]?.links ?? [] {
                guard let resolution = graph.resolve(source.link.target), resolution.path == notePath,
                      resolution.via != .alias, source.link.target != newName else { continue }
                edits.append(FileEdit(
                    path: path,
                    range: source.link.targetRange,
                    original: source.link.target,
                    replacement: newName,
                    context: source.snippet
                ))
            }
        }
        let folder = (notePath as NSString).deletingLastPathComponent
        let stem = Slug.make(newName)
        var newPath: String?
        if stem != note.fileStem {
            newPath = NoteTemplate.uniquePath(folder: folder, stem: stem, existing: existingPaths.subtracting([notePath]))
        }
        return Plan(notePath: notePath, oldName: note.name, newName: newName, edits: edits, newPath: newPath)
    }

    /// Carries out a plan: link edits (if `updateLinks`), the note's `name:`
    /// field, then the file move. Returns the note's path afterwards.
    @MainActor
    @discardableResult
    public static func apply(_ plan: Plan, updateLinks: Bool, store: ProjectStore) throws -> String {
        if updateLinks { try store.applyEdits(plan.edits) }
        let document = try store.document(at: plan.notePath)
        let renamed = Frontmatter.setting("name", to: .string(plan.newName), in: document.text)
        if renamed != document.text { document.text = renamed }
        store.save(document)
        guard let newPath = plan.newPath else { return plan.notePath }
        try store.moveFile(from: plan.notePath, to: newPath)
        return newPath
    }
}
