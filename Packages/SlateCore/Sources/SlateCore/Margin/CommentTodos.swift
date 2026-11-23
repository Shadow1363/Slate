import Foundation

/// A to-do written as a comment where the work is:
///
/// ```text
/// /* TODO: tighten this exchange due:2026-12-01 */     (script: Fountain boneyard)
/// %% TODO: check the 1987 dates %%                     (notes: Obsidian comment)
/// <!-- TODO: add her mother -->                        (notes: HTML comment)
/// ```
///
/// Ticking one changes `TODO:` to `DONE:`; the comment stays as a record.
public struct CommentTodo: Sendable, Equatable, Identifiable {
    /// The file, relative to the project root.
    public let path: String
    /// UTF-16 range of the whole comment, delimiters included.
    public let range: NSRange
    /// 0-based line the comment starts on.
    public let line: Int
    /// The comment as it was read, to check nothing moved before editing it.
    public let source: String
    public let done: Bool
    /// The words after `TODO:`, without `due:`.
    public let text: String
    /// `YYYY-MM-DD`.
    public let due: String?
    /// The scene a script comment sits in.
    public let sceneID: String?
    /// Where it is, for lists: the scene heading or the note's name.
    public let place: String

    public var id: String { "\(path)|\(range.location)|\(source)" }

    /// The same as a margin to-do, for due dates and sorting.
    public var asMarginTodo: MarginTodo {
        MarginTodo(line: line, source: source, done: done, text: text, sceneID: sceneID, due: due)
    }
}

public enum CommentTodos {
    /// `/* … */`, `%% … %%`, `<!-- … -->`, across lines.
    private static let comment = try! NSRegularExpression(
        pattern: #"/\*([\s\S]*?)\*/|%%([\s\S]*?)%%|<!--([\s\S]*?)-->"#)
    private static let marker = try! NSRegularExpression(pattern: #"^\s*(TODO|DONE)\s*:\s*"#, options: [.caseInsensitive])
    private static let dueToken = try! NSRegularExpression(pattern: #"(?:^|\s)due:(\d{4}-\d{2}-\d{2})\b"#)

    /// True for files whose comments are read: the script and Universe notes.
    public static func isScanned(_ path: String) -> Bool {
        // Act files only: not revisions, the margin or the title page.
        Films.isActFile(path) || (path.hasPrefix(ProjectLayout.universe + "/") && path.hasSuffix(".md"))
    }

    /// Every `TODO:` / `DONE:` comment in a file. Script files only count
    /// `/* */` (anything else there is screenplay text).
    public static func scan(text: String, path: String) -> [CommentTodo] {
        let isScript = path.hasPrefix(ProjectLayout.script + "/")
        let ns = text as NSString
        let parsed = isScript ? ScriptParser.parse(text) : nil
        let place = isScript ? "" : Note(path: path, text: text).name
        var result: [CommentTodo] = []
        for match in comment.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let group = (1...3).first { match.range(at: $0).location != NSNotFound } ?? 1
            if isScript && group != 1 { continue }
            let body = ns.substring(with: match.range(at: group))
            guard let mark = marker.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) else { continue }
            let word = (body as NSString).substring(with: mark.range(at: 1)).uppercased()
            var rest = (body as NSString).substring(from: NSMaxRange(mark.range))
            var due: String?
            if let found = dueToken.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                due = (rest as NSString).substring(with: found.range(at: 1))
                rest = (rest as NSString).replacingCharacters(in: found.range, with: "")
            }
            let words = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let line = ns.substring(to: match.range.location).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            let scene = parsed?.scenes.first { NSLocationInRange(match.range.location, $0.range) }
            result.append(CommentTodo(
                path: path, range: match.range, line: line, source: ns.substring(with: match.range),
                done: word == "DONE", text: words, due: due, sceneID: scene?.sceneID,
                place: isScript ? (scene?.heading ?? (path as NSString).lastPathComponent) : place))
        }
        return result
    }

    /// Every `%% … %%` and `<!-- … -->` comment in a note (for dimming), with
    /// the range of its `TODO`/`DONE` word if it has one.
    public static func noteComments(in text: String) -> [(range: NSRange, marker: NSRange?)] {
        let ns = text as NSString
        return comment.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let group = (2...3).first(where: { match.range(at: $0).location != NSNotFound }) else { return nil }
            let body = match.range(at: group)
            let bodyText = ns.substring(with: body)
            let marker = self.marker.firstMatch(in: bodyText, range: NSRange(location: 0, length: (bodyText as NSString).length))
                .map { NSRange(location: body.location + $0.range(at: 1).location, length: $0.range(at: 1).length) }
            return (match.range, marker)
        }
    }

    /// The comment with `TODO` and `DONE` swapped.
    public static func toggledSource(_ todo: CommentTodo) -> String {
        let source = todo.source as NSString
        let found = source.range(of: todo.done ? "DONE" : "TODO", options: [.caseInsensitive])
        guard found.location != NSNotFound else { return todo.source }
        return source.replacingCharacters(in: found, with: todo.done ? "TODO" : "DONE")
    }

    /// The text with this comment's `TODO:` turned into `DONE:` (or back),
    /// or nil if the comment isn't where it was read.
    public static func toggling(_ todo: CommentTodo, in text: String) -> String? {
        let ns = text as NSString
        guard NSMaxRange(todo.range) <= ns.length, ns.substring(with: todo.range) == todo.source else { return nil }
        return ns.replacingCharacters(in: todo.range, with: toggledSource(todo))
    }

    /// The comment to add a new to-do in a note, and where the caret goes in it.
    public static let newNoteComment = (text: "%% TODO:  %%", caret: 9)

    /// Every comment to-do in a project, read from disk.
    public static func inProject(root: URL) -> [CommentTodo] { scanProject(root: root).comments }

    /// Comment to-dos plus each scene's heading (by ID), from one pass over the files.
    public static func scanProject(root: URL) -> (comments: [CommentTodo], headings: [String: String]) {
        var comments: [CommentTodo] = []
        var headings: [String: String] = [:]
        for folder in [ProjectLayout.script, ProjectLayout.universe] {
            let base = root.appending(path: folder, directoryHint: .isDirectory)
            // Relative paths straight from the file system: no prefix arithmetic
            // (a folder can be reached as /var/… and /private/var/…).
            let subpaths = (try? FileManager.default.subpathsOfDirectory(atPath: base.path(percentEncoded: false))) ?? []
            for relative in subpaths.sorted() where !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                let path = folder + "/" + relative
                let url = base.appending(path: relative)
                guard isScanned(path), let text = try? CoordinatedFileIO.readText(url) else { continue }
                comments += scan(text: text, path: path)
                if folder == ProjectLayout.script {
                    for scene in ScriptParser.parse(text).scenes {
                        if let id = scene.sceneID { headings[id] = scene.heading }
                    }
                }
            }
        }
        return (comments, headings)
    }
}
