import AppKit
import Foundation
import Observation
import SlateCore

/// Search preferences: the shortcut and renamed bangs.
public enum SearchPreferences {
    /// `cmd+k`, `cmd+shift+space`…
    public static let shortcut = "search.shortcut"
    public static let defaultShortcut = "cmd+k"
    /// JSON: scope key → bang name.
    public static let bangRenames = "search.bangRenames"

    public static var renames: [String: String] {
        guard let text = UserDefaults.standard.string(forKey: bangRenames),
              let object = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return [:] }
        return object
    }

    public static func setRenames(_ renames: [String: String]) {
        let clean = renames.filter { !Bangs.normalize($0.value).isEmpty }
        if clean.isEmpty {
            UserDefaults.standard.removeObject(forKey: bangRenames)
        } else if let data = try? JSONEncoder().encode(clean) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: bangRenames)
        }
    }
}

/// The Search panel's state (⌘K): what's typed, the results, recents, and opening a result.
@MainActor
@Observable
final class SpotlightModel {
    let session: ProjectSession
    var query = "" { didSet { if query != oldValue { update() } } }
    private(set) var sections: [SearchSection] = []
    /// `!text` matches, filled in shortly after typing stops.
    private(set) var textResults: [ProjectSearch.FileResult] = []
    private(set) var searchingText = false
    /// Bangs matching the `!…` being typed.
    private(set) var bangSuggestions: [Bang] = []
    /// Tags matching the `#…` being typed.
    private(set) var tagSuggestions: [(tag: String, count: Int)] = []
    var highlighted = 0

    @ObservationIgnored private var items: [SearchItem] = []
    @ObservationIgnored private(set) var bangs: [Bang] = []
    @ObservationIgnored private var tagIndex = TagIndex(notes: [], scenes: [])
    @ObservationIgnored private var textTask: Task<Void, Never>?

    static let recentKey = "search.recent"

    init(session: ProjectSession, query: String = "") {
        self.session = session
        reload()
        self.query = query
        update()
    }

    /// Rebuilds the items from the project (on open, and after files change).
    func reload() {
        bangs = Bangs.all(templates: session.templates, renames: SearchPreferences.renames)
        items = session.searchItems()
        tagIndex = session.tagIndex
        update()
    }

    var parsed: SearchQuery { SearchQuery.parse(query, bangs: bangs) }

    var isTextSearch: Bool { parsed.has(.text) }

    /// Every result in display order (for ↑/↓ and Return).
    var flatResults: [SearchItem] { sections.flatMap(\.items) }

    /// Recent searches, newest first.
    var recentSearches: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    }

    private func update() {
        let parsed = parsed
        highlighted = 0
        if let partial = parsed.partial, partial.hasPrefix("!") {
            bangSuggestions = SearchEngine.suggestions(for: partial, bangs: bangs)
        } else if query.trimmingCharacters(in: .whitespaces) == "!" || query.trimmingCharacters(in: .whitespaces) == "!?" {
            bangSuggestions = bangs
        } else {
            bangSuggestions = []
        }
        if let partial = parsed.partial, partial.hasPrefix("#") {
            let prefix = Tags.normalize(partial)
            tagSuggestions = tagIndex.tags.filter { prefix.isEmpty || $0.tag.hasPrefix(prefix) }.prefix(12).map { $0 }
        } else {
            tagSuggestions = []
        }
        sections = parsed.isEmpty ? [] : SearchEngine.search(parsed, in: items)
        scheduleTextSearch(parsed)
    }

    /// Full text: everything for `!text`, a few lines under the names otherwise.
    private func scheduleTextSearch(_ parsed: SearchQuery) {
        textTask?.cancel()
        let words = ([parsed.text] + parsed.exact.map { "\"\($0)\"" }).filter { !$0.isEmpty }.joined(separator: " ")
        let plain = parsed.scopes.isEmpty && parsed.tags.isEmpty && parsed.filters.isEmpty
        guard (parsed.has(.text) || plain), words.count >= 2 else {
            textResults = []
            searchingText = false
            return
        }
        searchingText = true
        let root = session.store.rootURL
        let paths = session.allPaths.filter { ProjectSearch.isSearchable($0) && !Films.isRevisionCopy($0) }
        let overrides = session.store.documents.mapValues(\.text)
        let limit = parsed.has(.text) ? 500 : 12
        textTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                ProjectSearch.search(words, root: root, paths: paths, overrides: overrides)
            }.value
            guard !Task.isCancelled, let self else { return }
            var remaining = limit
            self.textResults = results.compactMap { file in
                guard remaining > 0 else { return nil }
                let kept = Array(file.matches.prefix(remaining))
                remaining -= kept.count
                return ProjectSearch.FileResult(path: file.path, matches: kept)
            }
            self.searchingText = false
        }
    }

    // MARK: Completing

    /// Replaces the `!…` or `#…` being typed with a full bang or tag.
    func complete(with text: String) {
        var words = query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if let last = words.last, last.hasPrefix("!") || last.hasPrefix("#") {
            words[words.count - 1] = text
        } else {
            words.append(text)
        }
        query = words.joined(separator: " ") + " "
    }

    // MARK: Opening

    func remember() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var recent = recentSearches.filter { $0 != trimmed }
        recent.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(8)), forKey: Self.recentKey)
    }

    /// Opens a result. Returns false when Search should stay open (a tag drills in).
    @discardableResult
    func open(_ item: SearchItem) -> Bool {
        if case .tag(let tag) = item.target {
            query = (bangs.first { $0.scope == .tag }.map { "!" + $0.name } ?? "!t") + " " + tag + " "
            return false
        }
        remember()
        session.open(item.target)
        return true
    }

    func open(_ match: ProjectSearch.Match) {
        remember()
        session.open(match.path, location: match.range.location)
    }
}

extension ProjectSession {
    /// Every tag on notes and on scenes of every film.
    var tagIndex: TagIndex {
        let saga = script.isSaga
        let current = script.film
        var scenes: [(id: String, heading: String, film: String?, tags: [String])] = []
        for scene in script.book.scenes {
            guard let id = scene.scene.sceneID else { continue }
            scenes.append((id, scene.scene.heading, saga ? current.title : nil, scene.scene.tags))
        }
        for outline in script.otherFilms {
            for scene in outline.scenes { scenes.append((scene.id, scene.heading, outline.film.title, scene.tags)) }
        }
        return TagIndex(notes: links.graph.notes, scenes: scenes)
    }

    /// Everything Search can find, in the order sections are listed.
    func searchItems() -> [SearchItem] {
        var items: [SearchItem] = []
        let graph = links.graph
        // Universe notes, by template order.
        let order = Dictionary(templates.enumerated().map { ($1.type, $0) }, uniquingKeysWith: { a, _ in a })
        let notes = graph.notes.filter { $0.path.hasPrefix(ProjectLayout.universe + "/") }
            .sorted { (order[$0.type ?? ""] ?? 99, $0.name) < (order[$1.type ?? ""] ?? 99, $1.name) }
        items += notes.map { SearchItems.note($0, template: template(for: $0.type)) }

        // Script: every film. The open one has exact pages; the others are estimated.
        let films = script.films
        let saga = films.count > 1
        for (number, film) in films.enumerated() {
            let book: ScriptBook
            if film.folder == script.film.folder {
                book = script.book
            } else if let outline = script.otherFilms.first(where: { $0.film.folder == film.folder }) {
                let paths = Films.actFiles(paths: script.scriptPaths, in: film)
                book = ScriptBook(parsed: Array(zip(paths, outline.parsed)).map { (path: $0, parsed: $1) })
            } else {
                continue
            }
            if saga {
                items.append(SearchItem(scope: .film, group: "Films", title: film.title,
                                        subtitle: "Film \(number + 1) · \(book.scenes.count) scenes", icon: "film.stack",
                                        target: .film(film.folder), fields: ["film": film.title, "filmnumber": String(number + 1)],
                                        id: "film|" + film.folder))
            }
            items += SearchItems.script(book, film: saga ? film.title : nil, filmNumber: number + 1)
        }

        // Storyboard frames, and scenes with none (`!b empty:`).
        let board = storyboard
        let plan = board.plan
        for scene in script.sagaScenes {
            guard let folder = plan.boarded[scene.id] else {
                items.append(SearchItem(scope: .frame, group: "Storyboard", title: scene.heading, subtitle: "No frames yet",
                                        icon: "rectangle.dashed", target: .frame(folder: "", file: nil, sceneID: scene.id),
                                        fields: ["empty": "yes", "film": saga ? scene.film.title : ""], id: "board-empty|" + scene.id))
                continue
            }
            for (index, frame) in (board.framesByFolder[folder.path]?.frames ?? []).enumerated() {
                let caption = frame.caption ?? ""
                items.append(SearchItem(
                    scope: .frame, group: "Storyboard",
                    title: caption.isEmpty ? "\(scene.heading) · frame \(index + 1)" : caption,
                    subtitle: [frame.shot, frame.move, scene.heading].compactMap { $0 }.joined(separator: " · "),
                    icon: frame.isClip ? "film" : "photo", target: .frame(folder: folder.path, file: frame.file, sceneID: scene.id),
                    fields: ["shot": frame.shot ?? "", "move": frame.move ?? "", "empty": "no", "film": saga ? scene.film.title : ""],
                    keywords: [scene.heading, frame.file], id: "frame|\(folder.path)/\(frame.file)"
                ))
            }
        }

        // Rough draft headings.
        if exists(ProjectLayout.draft) {
            let text = store.documents[ProjectLayout.draft]?.text ?? (try? store.readText(at: ProjectLayout.draft)) ?? ""
            for heading in MarkdownOutline(parsing: text).headings {
                items.append(SearchItem(scope: .draft, group: "Rough Draft", title: heading.title, subtitle: "Rough draft",
                                        icon: "doc.richtext", target: .path(ProjectLayout.draft, location: heading.range.location),
                                        id: "draft|\(heading.line)"))
            }
        }

        // Canvases, timelines and maps, with the events and places in them.
        for path in allPaths.filter({ $0.hasSuffix(".canvas") }).sorted() {
            let text = (try? store.readText(at: path)) ?? ""
            let cards = (try? CanvasFile(text: text))?.nodes.map(\.text).filter { !$0.isEmpty } ?? []
            items.append(SearchItem(scope: .canvas, group: "Canvases", title: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                    subtitle: "Canvas", icon: "rectangle.3.group", target: .path(path, location: nil),
                                    keywords: cards, id: "canvas|" + path))
        }
        for path in timelineFiles {
            guard let file = try? TimelineFile(text: store.documents[path]?.text ?? store.readText(at: path)) else { continue }
            let name = TimelinePane.title(path)
            for event in file.events {
                items.append(SearchItem(scope: .timeline, group: "Timeline Events", title: event.title, subtitle: "\(event.world) · \(name)",
                                        icon: "timeline.selection", target: .timelineEvent(path: path, id: event.id),
                                        fields: ["when": event.world], keywords: [event.world], id: "event|\(path)|\(event.id)"))
            }
        }
        for path in mapFiles {
            guard let file = try? MapFile(text: store.documents[path]?.text ?? store.readText(at: path)) else { continue }
            let name = MapPane.title(path)
            for item in file.pins + file.regions + file.paths {
                items.append(SearchItem(scope: .map, group: "Map Places", title: item.title, subtitle: "\(item.kind.title) · \(name)",
                                        icon: item.kind == .pin ? "mappin" : item.kind == .region ? "square.dashed" : "point.topleft.down.to.point.bottomright.curvepath",
                                        target: .mapItem(path: path, id: item.id), fields: ["kind": item.kind.rawValue],
                                        id: "place|\(path)|\(item.id)"))
            }
        }

        // Margin.
        let scenesByID = Dictionary(script.sagaScenes.map { ($0.id, $0.heading) }, uniquingKeysWith: { a, _ in a })
        for todo in script.margin.todos {
            items.append(SearchItem(scope: .todo, group: "To-dos", title: todo.text,
                                    subtitle: [todo.due.map { "Due \($0)" }, todo.sceneID.flatMap { scenesByID[$0] }].compactMap { $0 }.joined(separator: " · "),
                                    icon: todo.done ? "checkmark.circle.fill" : "circle", target: .todo(line: todo.line, sceneID: todo.sceneID, quote: todo.quote),
                                    fields: ["done": todo.done ? "yes" : "no", "due": todo.due ?? "", "scene": todo.sceneID ?? ""],
                                    keywords: [todo.quote ?? ""], id: "todo|\(todo.line)"))
        }
        for note in script.margin.notes {
            let first = note.markdown.split(separator: "\n").first.map(String.init) ?? "Margin note"
            items.append(SearchItem(scope: .marginNote, group: "Margin Notes", title: first,
                                    subtitle: note.sceneID.flatMap { scenesByID[$0] } ?? "Margin note", icon: "note.text",
                                    target: .marginNote(sceneID: note.sceneID, quote: note.quote), keywords: [note.markdown],
                                    id: "mnote|\(note.id)"))
        }

        // Dictionary.
        for entry in dictionary.entries {
            items.append(SearchItem(scope: .word, group: "Dictionary", title: entry.word,
                                    subtitle: [entry.part, entry.explanation.split(separator: "\n").first.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                                    icon: "character.book.closed", target: .word(entry.word), keywords: entry.forms + [entry.explanation],
                                    id: "word|" + entry.word))
        }

        items += SearchItems.tags(tagIndex)

        // Files.
        for path in allPaths.sorted() where !path.hasPrefix(ProjectLayout.exports + "/") && !Films.isRevisionCopy(path) {
            items.append(SearchItem(scope: .file, group: "Files", title: (path as NSString).lastPathComponent,
                                    subtitle: (path as NSString).deletingLastPathComponent, icon: ProjectLayout.isTextFile(path) ? "doc.text" : "doc",
                                    target: .path(path, location: nil), keywords: [path], id: "file|" + path))
        }
        return items
    }

    /// Where a picked result goes.
    func open(_ target: SearchTarget) {
        switch target {
        case .path(let path, let location):
            open(path, location: location)
        case .scene(let id):
            open(sceneID: id)
        case .film(let folder):
            area = .script
            if let film = script.films.first(where: { $0.folder == folder }) { script.select(film: film) }
        case .word(let word):
            area = .dictionary
            if let entry = dictionary.entries.first(where: { $0.word == word }) {
                dictionarySelection = DictionarySelection(entry, isGlobal: dictionary.isGlobal(entry))
            }
        case .todo(_, let sceneID, let quote):
            area = .script
            script.showingMargin = true
            script.margin.tab = .todos
            if let sceneID { script.reveal(sceneID: sceneID, quote: quote) } else { script.margin.scope = .all }
        case .marginNote(let sceneID, let quote):
            area = .script
            script.showingMargin = true
            script.margin.tab = .notes
            if let sceneID { script.reveal(sceneID: sceneID, quote: quote) }
        case .timelineEvent(let path, let id):
            pendingItemSelection = PendingSelection(path: path, id: id)
            area = .universe
            universeSelection = path
        case .mapItem(let path, let id):
            mapReveal = MapRevealRequest(path: path, item: id)
            open(path)
        case .frame(let folder, let file, let sceneID):
            if let film = script.film(containingScene: sceneID) { script.select(film: film) }
            area = .storyboard
            storyboard.focusedRow = sceneID
            if let file, !folder.isEmpty { storyboard.select(FrameRef(folder: folder, file: file)) }
        case .tag:
            break
        }
    }
}

/// A timeline event or map place Search asked to select once its file opens.
struct PendingSelection: Equatable {
    let path: String
    let id: String
}
