import Foundation
import Observation

/// One `[[link]]` somewhere in the project, with where it sits.
public struct LinkSource: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// A universe note.
        case note
        /// The project's word book (`dictionary/words.md`): indexed for its
        /// links, but not a link target.
        case dictionary
        /// A `.canvas` board: note cards and `[[links]]` in text cards.
        case canvas
        /// A `*.timeline.json`: lanes' notes and events' locations.
        case timeline
        /// A `*.map.json`: the notes pins, regions and paths link to.
        case map
        /// A line in a script act file.
        case scene
        /// `script/margin/*.md`.
        case margin
        /// `universe/draft.md`: indexed for its links, but not a link target.
        case draft
    }

    public let path: String
    public let kind: Kind
    public let link: WikiLink
    /// 0-based line of the link in its file.
    public let line: Int
    /// The line, trimmed, for showing context.
    public let snippet: String
    public let sceneID: String?
    public let sceneHeading: String?

    public var id: String { "\(path)@\(link.range.location)" }
}

/// What the index keeps per file. Cached in `.slate/index/links.json`.
public struct IndexedFile: Sendable, Equatable, Codable {
    public let path: String
    public var modified: Date?
    public var size: Int?
    /// Set for universe notes.
    public let note: Note?
    public let links: [LinkSource]

    /// Which files the link index reads.
    public static func isIndexed(_ path: String) -> Bool {
        kind(of: path) != nil
    }

    static func kind(of path: String) -> LinkSource.Kind? {
        let ext = (path as NSString).pathExtension.lowercased()
        let components = path.split(separator: "/")
        guard let area = components.first else { return nil }
        switch area {
        case "universe":
            if path == ProjectLayout.draft { return .draft }
            if ext == "canvas" { return .canvas }
            if path.lowercased().hasSuffix(TimelineFile.suffix) { return .timeline }
            if path.lowercased().hasSuffix(MapFile.suffix) { return .map }
            return ["md", "markdown"].contains(ext) ? .note : nil
        case "dictionary":
            return path == WordBook.path ? .dictionary : nil
        case "script":
            if components.count == 3, components[1] == "margin", ext == "md" { return .margin }
            if components.count == 2, components[1] != "title-page.md", ["md", "fountain", "txt"].contains(ext) { return .scene }
            return nil
        default:
            return nil
        }
    }

    /// Reads one file's note fields and links.
    public static func index(path: String, text: String, modified: Date? = nil, size: Int? = nil) -> IndexedFile {
        guard let kind = kind(of: path) else {
            return IndexedFile(path: path, modified: modified, size: size, note: nil, links: [])
        }
        let lines = LineTable(text)
        func source(_ link: WikiLink, sceneID: String? = nil, heading: String? = nil) -> LinkSource {
            let line = lines.line(containing: link.range.location)
            return LinkSource(
                path: path, kind: kind, link: link, line: line,
                snippet: lines.text(ofLine: line).trimmingCharacters(in: .whitespaces),
                sceneID: sceneID, sceneHeading: heading
            )
        }
        switch kind {
        case .note:
            let note = Note(path: path, text: text)
            return IndexedFile(path: path, modified: modified, size: size, note: note, links: note.links.map { source($0) })
        case .margin, .draft, .dictionary:
            let outline = MarkdownOutline(parsing: text)
            return IndexedFile(path: path, modified: modified, size: size, note: nil,
                               links: WikiLink.find(in: text, excluding: outline.codeRanges).map { source($0) })
        case .canvas:
            // Links typed in text cards, then note cards (`"file":"universe/…md"`).
            var links = WikiLink.find(in: text).map { source($0) }
            let ns = text as NSString
            for match in canvasFilePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let pathRange = match.range(at: 1)
                let target = ns.substring(with: pathRange).replacingOccurrences(of: "\\/", with: "/")
                guard target.hasPrefix(ProjectLayout.universe + "/"), ["md", "markdown"].contains((target as NSString).pathExtension.lowercased()) else { continue }
                let link = WikiLink(range: match.range, targetRange: pathRange, target: target, heading: nil, shown: nil)
                let line = lines.line(containing: match.range.location)
                links.append(LinkSource(path: path, kind: kind, link: link, line: line, snippet: "Note card on this canvas",
                                        sceneID: nil, sceneHeading: nil))
            }
            return IndexedFile(path: path, modified: modified, size: size, note: nil, links: links)
        case .timeline, .map:
            // `"note": "c-7f3a"` and `"location": "The Station"`: an id, a path or a name.
            var links = WikiLink.find(in: text).map { source($0) }
            let ns = text as NSString
            let titles = jsonTitlePattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            let place = kind == .timeline ? "this timeline" : "this map"
            // Only the keys Slate reads count (not a `note` inside some other app's data).
            let references = jsonReferences(text, kind: kind)
            for match in jsonNotePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let valueRange = match.range(at: 2)
                let target = ns.substring(with: valueRange).replacingOccurrences(of: "\\/", with: "/")
                guard !target.isEmpty, references.contains(target) else { continue }
                let link = WikiLink(range: match.range, targetRange: valueRange, target: target, heading: nil, shown: nil)
                let owner = titles.last { $0.range.location < match.range.location }.map { ns.substring(with: $0.range(at: 1)) }
                let snippet = owner.map { "“\($0)” on \(place)" } ?? "On \(place)"
                links.append(LinkSource(path: path, kind: kind, link: link, line: lines.line(containing: match.range.location),
                                        snippet: snippet, sceneID: nil, sceneHeading: nil))
            }
            return IndexedFile(path: path, modified: modified, size: size, note: nil, links: links)
        case .scene:
            let parsed = ScriptParser.parse(text)
            let links = WikiLink.find(in: text).map { link -> LinkSource in
                let line = parsed.lineIndex(containing: link.range.location)
                let scene = parsed.sceneIndex(containingLine: line).map { parsed.scenes[$0] }
                return source(link, sceneID: scene?.sceneID, heading: scene?.heading)
            }
            return IndexedFile(path: path, modified: modified, size: size, note: nil, links: links)
        }
    }
}

/// `"file":"…"` in a canvas file; group 1 is the path.
let canvasFilePattern = try! NSRegularExpression(pattern: #""file"\s*:\s*"((?:[^"\\]|\\.)*)""#)

/// `"note": "…"` or `"location": "…"` in a timeline or map; group 2 is the value.
let jsonNotePattern = try! NSRegularExpression(pattern: #""(note|location)"\s*:\s*"((?:[^"\\]|\\.)*)""#)

/// The note references a timeline (lanes' notes, events' locations) or map (items' notes) holds.
func jsonReferences(_ text: String, kind: LinkSource.Kind) -> Set<String> {
    if kind == .timeline, let file = try? TimelineFile(text: text) {
        return Set(file.lanes.compactMap(\.note) + file.events.compactMap(\.location))
    }
    if kind == .map, let file = try? MapFile(text: text) {
        return Set(file.items.compactMap(\.note))
    }
    return []
}

/// `"title": "…"` or `"name": "…"`, for naming what a link sits on.
let jsonTitlePattern = try! NSRegularExpression(pattern: #""(?:title|name)"\s*:\s*"((?:[^"\\]|\\.)*)""#)

/// The resolved web of links: names → notes, and notes → backlinks.
/// Pure data, rebuilt whenever a file changes.
public struct LinkGraph: Sendable, Equatable {
    public enum Match: String, Sendable { case name, alias, id, fileName }

    public struct Resolution: Sendable, Equatable {
        public let path: String
        public let via: Match
    }

    public struct Completion: Sendable, Equatable, Identifiable {
        /// What to write in the link: the name or alias typed against.
        public let text: String
        public let note: Note
        public let isAlias: Bool
        public var id: String { note.path + "|" + text }
    }

    public let files: [String: IndexedFile]
    /// Notes sorted by name.
    public let notes: [Note]
    private let byName: [String: String]
    private let byAlias: [String: String]
    private let byStem: [String: String]
    private let byID: [String: String]
    private let incoming: [String: [LinkSource]]

    public init(files: [IndexedFile]) {
        var map: [String: IndexedFile] = [:]
        for file in files { map[file.path] = file }
        self.files = map
        let sortedPaths = map.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var byName: [String: String] = [:]
        var byAlias: [String: String] = [:]
        var byStem: [String: String] = [:]
        var byID: [String: String] = [:]
        var notes: [Note] = []
        for path in sortedPaths {
            guard let note = map[path]?.note else { continue }
            notes.append(note)
            // First by path wins, so resolution is stable.
            if byName[Self.key(note.name)] == nil { byName[Self.key(note.name)] = path }
            for alias in note.aliases where byAlias[Self.key(alias)] == nil {
                byAlias[Self.key(alias)] = path
            }
            if byStem[Self.key(note.fileStem)] == nil { byStem[Self.key(note.fileStem)] = path }
            // A full path (a canvas note card) resolves to that note.
            byStem[Self.key(path)] = path
            // So does an `id:` (timeline lanes, map pins).
            if let id = note.noteID, byID[id] == nil { byID[id] = path }
        }
        self.byName = byName
        self.byAlias = byAlias
        self.byStem = byStem
        self.byID = byID
        self.notes = notes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var incoming: [String: [LinkSource]] = [:]
        for path in sortedPaths {
            for source in map[path]?.links ?? [] {
                guard let target = Self.resolve(source.link.target, byName: byName, byAlias: byAlias, byID: byID, byStem: byStem) else { continue }
                incoming[target.path, default: []].append(source)
            }
        }
        self.incoming = incoming
    }

    public static let empty = LinkGraph(files: [])

    /// Name, then alias, then file name; case and accents don't matter.
    public func resolve(_ target: String) -> Resolution? {
        Self.resolve(target, byName: byName, byAlias: byAlias, byID: byID, byStem: byStem)
    }

    public func note(at path: String) -> Note? { files[path]?.note }

    public func note(named target: String) -> Note? {
        resolve(target).flatMap { note(at: $0.path) }
    }

    /// Every link that points at the note, in path order.
    public func backlinks(to path: String) -> [LinkSource] {
        (incoming[path] ?? []).filter { $0.path != path }
    }

    /// Links in a file whose target matches no note.
    public func unresolved(in path: String) -> [LinkSource] {
        (files[path]?.links ?? []).filter { resolve($0.link.target) == nil }
    }

    /// All unresolved links in the project.
    public var unresolved: [LinkSource] {
        files.keys.sorted().flatMap { unresolved(in: $0) }
    }

    /// Notes whose name or alias starts with (then contains) what was typed.
    public func completions(prefix typed: String, limit: Int = 20) -> [Completion] {
        let query = Self.key(typed)
        var prefixed: [Completion] = []
        var contained: [Completion] = []
        for note in notes {
            for (text, isAlias) in [(note.name, false)] + note.aliases.map({ ($0, true) }) {
                let key = Self.key(text)
                if query.isEmpty || key.hasPrefix(query) {
                    prefixed.append(Completion(text: text, note: note, isAlias: isAlias))
                } else if key.contains(query) {
                    contained.append(Completion(text: text, note: note, isAlias: isAlias))
                }
            }
        }
        // A note's own name before its aliases, then shorter names first.
        let order: (Completion, Completion) -> Bool = {
            if $0.isAlias != $1.isAlias { return !$0.isAlias }
            return $0.text.localizedStandardCompare($1.text) == .orderedAscending
        }
        return Array((prefixed.sorted(by: order) + contained.sorted(by: order)).prefix(limit))
    }

    /// The comparison key for names: case-, accent- and spacing-insensitive.
    public static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func resolve(_ target: String, byName: [String: String], byAlias: [String: String], byID: [String: String],
                                byStem: [String: String]) -> Resolution? {
        let key = key(target)
        if let path = byName[key] { return Resolution(path: path, via: .name) }
        if let path = byAlias[key] { return Resolution(path: path, via: .alias) }
        if let path = byID[target.trimmingCharacters(in: .whitespaces)] { return Resolution(path: path, via: .id) }
        if let path = byStem[key] ?? byStem[Slug.make(target)] { return Resolution(path: path, via: .fileName) }
        return nil
    }
}

/// Where a character appears in the script, from the cues.
public struct CharacterAppearances: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let scene: ScriptBook.Scene
        public let speeches: Int
        public var id: String { scene.id }
    }

    public let entries: [Entry]
    public var totalSpeeches: Int { entries.reduce(0) { $0 + $1.speeches } }

    /// Scenes where any of `names` speaks (cue match, case-insensitive), or is
    /// linked from the scene.
    public init(names: [String], book: ScriptBook, linkedScenes: Set<String> = []) {
        let wanted = Set(names.map { $0.uppercased() }.filter { !$0.isEmpty })
        var entries: [Entry] = []
        for scene in book.scenes {
            guard let file = book.files.first(where: { $0.path == scene.file }) else { continue }
            var speeches = 0
            for index in scene.scene.lines where file.parsed.lines[index].kind == .character {
                if let cue = ScriptParser.characterName(fromCue: file.parsed.lines[index].text), wanted.contains(cue) {
                    speeches += 1
                }
            }
            if speeches > 0 || scene.scene.sceneID.map(linkedScenes.contains) == true {
                entries.append(Entry(scene: scene, speeches: speeches))
            }
        }
        self.entries = entries
    }
}

/// Keeps a `LinkGraph` up to date for one open project.
///
/// Reads come from `ProjectStore` (open buffers win over disk, so unsaved
/// edits count). `.slate/index/links.json` caches each file's results by
/// modification date and size; it is only a speed-up and is rebuilt freely.
@MainActor
@Observable
public final class LinkIndex {
    public private(set) var graph: LinkGraph = .empty
    /// Bumped on every change, for views that cache derived data.
    public private(set) var version = 0

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private var entries: [String: IndexedFile] = [:]

    public static let cachePath = ".slate/index/links.json"
    /// Bump when `IndexedFile` changes shape, so old caches are ignored.
    static let cacheVersion = 5

    public init(store: ProjectStore) {
        self.store = store
        entries = loadCache()
        refresh()
    }

    /// Re-checks every indexed file against the folder; call when
    /// `ProjectStore.files` changes. Unchanged files keep their entries.
    public func refresh() {
        var updated: [String: IndexedFile] = [:]
        let paths = store.files.values.flatMap { $0 }.map(\.relativePath).filter(IndexedFile.isIndexed)
        for path in paths {
            let open = store.documents[path]
            let attributes = (try? store.url(for: path)).flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
            let modified = attributes?[.modificationDate] as? Date
            let size = (attributes?[.size] as? NSNumber)?.intValue
            if open?.isDirty != true, let cached = entries[path], cached.modified == modified, cached.size == size, modified != nil {
                updated[path] = cached
                continue
            }
            guard let text = try? store.readText(at: path) else { continue }
            var entry = IndexedFile.index(path: path, text: text, modified: modified, size: size)
            if open?.isDirty == true { entry.modified = nil }
            updated[path] = entry
        }
        let changed = updated != entries
        entries = updated
        if changed || graph.files.isEmpty && !updated.isEmpty {
            publish()
            saveCache()
        }
    }

    /// Re-reads one file from text being edited (before it is saved).
    public func update(path: String, text: String) {
        guard IndexedFile.isIndexed(path) else { return }
        let entry = IndexedFile.index(path: path, text: text)
        guard entries[path]?.note != entry.note || entries[path]?.links != entry.links else { return }
        entries[path] = entry
        publish()
    }

    private func publish() {
        graph = LinkGraph(files: Array(entries.values))
        version += 1
    }

    // MARK: - Cache

    private struct Cache: Codable {
        var version: Int
        var files: [IndexedFile]
    }

    private var cacheURL: URL { store.rootURL.appending(path: Self.cachePath) }

    private func loadCache() -> [String: IndexedFile] {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Self.cacheVersion else { return [:] }
        return Dictionary(cache.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func saveCache() {
        let saved = entries.values.filter { $0.modified != nil }.sorted { $0.path < $1.path }
        guard let data = try? JSONEncoder().encode(Cache(version: Self.cacheVersion, files: saved)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
