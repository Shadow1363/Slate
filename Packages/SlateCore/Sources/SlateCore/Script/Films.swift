import Foundation

/// One screenplay in a project. A project holds one film (act files directly
/// in `script/`) or a saga: one folder per film, `script/01 Tidewater/`,
/// `script/02 Slack Water/`, each with its own act files, title page,
/// `production.json`, revisions and snapshots. The margin (`script/margin/`)
/// and everything outside `script/` are shared, so scene IDs are unique across
/// the whole project and a storyboard folder, to-do or timeline event always
/// points at one scene.
public struct Film: Sendable, Hashable, Identifiable {
    /// `script`, or `script/02 Slack Water`.
    public let folder: String
    /// The folder name without its number (`Slack Water`), or the project name for `script/` itself.
    public let title: String

    public var id: String { folder }
    public var isRoot: Bool { folder == ProjectLayout.script }
    /// The folder's own name (`02 Slack Water`), or `script`.
    public var folderName: String { (folder as NSString).lastPathComponent }

    public init(folder: String, title: String) {
        self.folder = folder
        self.title = title
    }

    public func path(_ name: String) -> String { folder + "/" + name }
    public var titlePagePath: String { path("title-page.md") }
    public var productionPath: String { path("production.json") }
    public var revisionsFolder: String { path("revisions") }
    public var snapshotsFolder: String { path(".snapshots") }
}

/// Scene IDs and headings of a film that isn't open, for storyboard folders,
/// ID allocation and the saga-wide scene order.
public struct FilmOutline: Sendable, Equatable {
    public struct Scene: Sendable, Equatable {
        public let id: String
        public let heading: String
        public var tags: [String] = []
        public init(id: String, heading: String, tags: [String] = []) {
            self.id = id
            self.heading = heading
            self.tags = tags
        }
    }

    public let film: Film
    public let scenes: [Scene]
    /// Every act file parsed, in order (for duplicate-ID repair).
    public let parsed: [ParsedScript]

    public init(film: Film, parsed: [ParsedScript]) {
        self.film = film
        self.parsed = parsed
        scenes = parsed.flatMap { file in file.scenes.compactMap { scene in scene.sceneID.map { Scene(id: $0, heading: scene.heading, tags: scene.tags) } } }
    }
}

public enum Films {
    /// Folders in `script/` that belong to the project, not to a film.
    public static let reserved: Set<String> = ["margin", "revisions"]

    static func isScriptFileName(_ name: String) -> Bool {
        name != "title-page.md" && !name.hasPrefix(".") && ["md", "fountain", "txt"].contains((name as NSString).pathExtension.lowercased())
    }

    static func isFilmFolderName(_ name: String) -> Bool {
        !name.hasPrefix(".") && !reserved.contains(name.lowercased())
    }

    /// `02 Slack Water` → `Slack Water`; `03-the-end` → `the-end`.
    public static func title(fromFolderName name: String) -> String {
        var rest = Substring(name)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < rest.count else { return name }
        rest = rest.dropFirst(digits.count)
        let trimmed = rest.drop { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }
        return trimmed.isEmpty ? name : String(trimmed)
    }

    /// `02 Slack Water`: a Finder-safe name with a two-digit number, so films sort in saga order.
    public static func folderName(number: Int, title: String) -> String {
        String(format: "%02d ", number) + ProjectCreator.folderName(for: title)
    }

    /// The films in a project, in saga order, from project-relative file paths.
    /// `script/` itself is a film when it has act files, or when there are no film folders.
    public static func films(paths: [String], projectName: String) -> [Film] {
        var rootHasActs = false
        var folders: Set<String> = []
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.first == ProjectLayout.script, parts.count >= 2 else { continue }
            if parts.count == 2 {
                if isScriptFileName(parts[1]) { rootHasActs = true }
            } else if isFilmFolderName(parts[1]) {
                folders.insert(parts[1])
            }
        }
        var films = folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Film(folder: ProjectLayout.script + "/" + $0, title: title(fromFolderName: $0)) }
        if rootHasActs || films.isEmpty {
            films.insert(Film(folder: ProjectLayout.script, title: projectName), at: 0)
        }
        return films
    }

    /// A film's act files (project-relative paths), in the order they join.
    public static func actFiles(paths: [String], in film: Film) -> [String] {
        let prefix = film.folder + "/"
        return paths.filter { path in
            guard path.hasPrefix(prefix) else { return false }
            let rest = path.dropFirst(prefix.count)
            return !rest.contains("/") && isScriptFileName(String(rest))
        }
        .sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    /// The film a path belongs to (an act file, its title page, revisions…), if any.
    public static func film(containing path: String, in films: [Film]) -> Film? {
        films.filter { !$0.isRoot }.first { path.hasPrefix($0.folder + "/") }
            ?? films.first { $0.isRoot && path.hasPrefix(ProjectLayout.script + "/") && !path.dropFirst(ProjectLayout.script.count + 1).contains("/") }
    }

    /// Whether a path is an act file of any film.
    public static func isActFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == ProjectLayout.script else { return false }
        switch parts.count {
        case 2: return isScriptFileName(parts[1])
        case 3: return isFilmFolderName(parts[1]) && isScriptFileName(parts[2])
        default: return false
        }
    }

    /// Whether a path is inside some film's `revisions/` (baselines that aren't the script).
    public static func isRevisionCopy(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == ProjectLayout.script else { return false }
        return (parts.count > 2 && parts[1] == "revisions") || (parts.count > 3 && isFilmFolderName(parts[1]) && parts[2] == "revisions")
    }

    // MARK: On disk

    /// Every film with its act files' URLs, read straight from the folder
    /// (for Home cards, covers and migrations, without a store).
    public static func onDisk(root: URL, projectName: String = "") -> [(film: Film, files: [URL])] {
        let fm = FileManager.default
        let script = root.appending(path: ProjectLayout.script, directoryHint: .isDirectory)
        var paths: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: script.path)) ?? [] where !name.hasPrefix(".") {
            var isFolder: ObjCBool = false
            fm.fileExists(atPath: script.appending(path: name).path, isDirectory: &isFolder)
            if isFolder.boolValue {
                guard isFilmFolderName(name) else { continue }
                let inner = (try? fm.contentsOfDirectory(atPath: script.appending(path: name).path)) ?? []
                paths += inner.map { "\(ProjectLayout.script)/\(name)/\($0)" }
                if inner.isEmpty { paths.append("\(ProjectLayout.script)/\(name)/") }
            } else {
                paths.append("\(ProjectLayout.script)/\(name)")
            }
        }
        return films(paths: paths, projectName: projectName).map { film in
            (film, actFiles(paths: paths, in: film).map { root.appending(path: $0) })
        }
    }

    /// What a single-film project moves when it becomes a saga: its act files,
    /// title page, production lock, revisions and snapshots go into `script/01 <title>/`.
    /// Returns (from, to) pairs of project-relative paths.
    public static func sagaMoves(paths: [String], projectName: String, hiddenFolders: [String] = []) -> (film: Film, moves: [(from: String, to: String)]) {
        let folder = ProjectLayout.script + "/" + folderName(number: 1, title: projectName)
        let film = Film(folder: folder, title: title(fromFolderName: (folder as NSString).lastPathComponent))
        var moves: [(String, String)] = []
        var seen: Set<String> = []
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.first == ProjectLayout.script, parts.count >= 2 else { continue }
            let top = parts[1]
            let movable = parts.count == 2
                ? (isScriptFileName(top) || top == "title-page.md" || top == "production.json")
                : top == "revisions"
            guard movable, !seen.contains(top) else { continue }
            seen.insert(top)
            moves.append(("\(ProjectLayout.script)/\(top)", "\(folder)/\(top)"))
        }
        for hidden in hiddenFolders where !seen.contains(hidden) {
            moves.append(("\(ProjectLayout.script)/\(hidden)", "\(folder)/\(hidden)"))
        }
        return (film, moves.sorted { $0.0 < $1.0 })
    }

    /// Points JSON references (canvas file cards) at moved files: `"script/01-act-one.md"`
    /// becomes `"script/01 Tidewater/01-act-one.md"`, also inside a folder that moved.
    public static func rewritingPaths(in json: String, moves: [(from: String, to: String)]) -> String {
        var text = json
        for move in moves {
            text = text.replacingOccurrences(of: "\"" + move.from + "\"", with: "\"" + move.to + "\"")
                .replacingOccurrences(of: "\"" + move.from + "/", with: "\"" + move.to + "/")
        }
        return text
    }

    /// Starter files for a new film: a title page and the first act file.
    public static func starterFiles(for film: Film, date: Date = .now) -> [String: String] {
        let draftDate = date.formatted(.dateTime.year().month(.wide).day())
        return [
            film.titlePagePath: "Title: \(film.title)\nCredit: written by\nAuthor:\nDraft date: \(draftDate)\n",
            film.path("01-act-one.md"): "# ACT ONE\n\n",
        ]
    }
}
