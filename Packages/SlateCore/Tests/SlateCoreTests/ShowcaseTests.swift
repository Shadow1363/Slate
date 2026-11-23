import Foundation
import Testing
@testable import SlateCore

/// `Showcase/Tidewater` is a hand-made demo project. These checks keep it
/// valid as Slate grows: every file reads, every link and scene ID points
/// somewhere, and only the warnings left in on purpose appear.
@MainActor
@Suite("Showcase project")
struct ShowcaseTests {
    static let root = Fixtures.root.deletingLastPathComponent().appending(path: "Showcase/Tidewater", directoryHint: .isDirectory)

    /// A throwaway copy, so opening it never writes `.slate/` into the repo.
    static func open(_ folder: TempFolder) throws -> ProjectStore {
        let copy = folder.url.appending(path: "Tidewater", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: root, to: copy)
        return try ProjectStore(rootURL: copy, autosaveDelay: nil)
    }

    static func paths(_ store: ProjectStore) -> [String] {
        store.files.values.flatMap { $0 }.map(\.relativePath).sorted()
    }

    /// Tidewater is a saga: the first film, then its sequel.
    static func films(_ store: ProjectStore) -> [Film] {
        Films.films(paths: paths(store), projectName: store.manifest.name)
    }

    /// One film's script (the first, Tidewater, by default).
    static func book(_ store: ProjectStore, film: Int = 0) throws -> ScriptBook {
        let acts = Films.actFiles(paths: paths(store), in: films(store)[film])
        return ScriptBook(texts: try acts.map { (path: $0, text: try store.readText(at: $0)) })
    }

    @Test func manifestAndScript() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        #expect(store.manifest.schemaVersion == ProjectManifest.currentSchemaVersion)
        let book = try Self.book(store)
        #expect(book.files.map(\.name) == ["01-act-one.md", "02-act-two.md", "03-act-three.md"])
        let ids = book.scenes.compactMap(\.scene.sceneID)
        // s011 was added after the script was locked (Milestone 11), so it sits between s004 and s005.
        #expect(ids == ["s001", "s002", "s003", "s004", "s011", "s005", "s006", "s007", "s008", "s009", "s010"])
        // Every script element is used at least once.
        let kinds = Set(book.files.flatMap { $0.parsed.lines.map(\.kind) })
        for kind in [ScriptElementKind.sceneHeading, .action, .character, .parenthetical, .dialogue, .transition,
                     .centered, .lyric, .synopsis, .boneyard, .section, .pageBreak] {
            #expect(kinds.contains(kind), "No \(kind) in the showcase script")
        }
        #expect(book.scenes.contains { $0.scene.durationOverride != nil })
    }

    @Test func notesLinksAndDictionary() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        let index = LinkIndex(store: store)
        let graph = index.graph
        #expect(graph.notes.allSatisfy { $0.frontmatterError == nil })
        #expect(Set(graph.notes.compactMap(\.type)).isSuperset(of: ["character", "location", "rule", "faction", "item", "event", "note", "vessel", "Character"]))
        #expect(graph.unresolved.map(\.link.target).isEmpty, "Unresolved: \(graph.unresolved.map(\.link.target))")
        let words = try WordBook.parse(store.readText(at: WordBook.path))
        #expect(words.contains { $0.isSpellingOnly })
        #expect(words.contains { !$0.forms.isEmpty })
        #expect(words.contains { !$0.links.isEmpty })
    }

    @Test func marginAnchorsExist() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        // The margin is shared by both films.
        let ids = try Self.book(store, film: 0).sceneIDs.union(Self.book(store, film: 1).sceneIDs)
        let todos = MarginTodos.parse(try store.readText(at: "script/margin/todos.md"))
        #expect(todos.count == 7)
        #expect(todos.compactMap(\.sceneID).allSatisfy(ids.contains))
        let notes = MarginNotes.parse(try store.readText(at: "script/margin/notes.md"))
        #expect(notes.compactMap(\.sceneID).allSatisfy(ids.contains))
    }

    @Test func canvasTimelinesAndMaps() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        let all = Set(Self.paths(store))
        let book = try Self.book(store)
        let graph = LinkIndex(store: store).graph

        let canvas = try CanvasFile(text: store.readText(at: "universe/canvases/story-web.canvas"))
        for node in canvas.nodes {
            if let file = node.file { #expect(all.contains(file), "Canvas card points at a missing \(file)") }
            if case .scene(_, let id) = node.card { #expect(book.sceneIDs.contains(id)) }
        }
        #expect(Set(canvas.nodes.map(\.typeName)) == ["text", "file", "link", "group"])

        var order: [String: Int] = [:]
        for scene in book.scenes { if let id = scene.scene.sceneID { order[id] = scene.number } }
        let samePlace: (String, String) -> Bool = { (graph.resolve($0)?.path ?? $0) == (graph.resolve($1)?.path ?? $1) }
        var units: Set<TimeUnits> = []
        for path in all where path.hasSuffix(TimelineFile.suffix) {
            let file = try TimelineFile(text: store.readText(at: path))
            units.insert(file.units)
            let warnings = TimelineAnalysis(file: file, sceneOrder: order).warnings(samePlace: samePlace)
            if path.hasSuffix("main.timeline.json") {
                // Left in on purpose: Ida is at the market and the office at once.
                #expect(warnings.map(\.kind) == [.twoPlaces], "\(warnings.map(\.message))")
                #expect(file.jumps.count == 2)
            } else {
                #expect(warnings.isEmpty, "\(path): \(warnings.map(\.message))")
            }
            for lane in file.lanes { #expect(lane.note.map { graph.resolve($0) != nil } ?? true) }
        }
        #expect(units == Set(TimeUnits.allCases))

        let maps = all.filter { $0.hasSuffix(MapFile.suffix) }
        #expect(maps.count == 2)
        for path in maps {
            let map = try MapFile(text: store.readText(at: path))
            if let image = map.image { #expect(all.contains(MapFile.imagePath(image, mapPath: path))) }
            for item in map.items {
                #expect(item.scenes.allSatisfy(book.sceneIDs.contains))
                if let note = item.note { #expect(graph.resolve(note) != nil, "\(item.title) → \(note)") }
            }
        }
    }

    @Test func storyboards() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        let all = Self.paths(store)
        let book = try Self.book(store)
        // Both films' scenes: the sequel's boards aren't "missing".
        let scenes = (book.scenes + (try Self.book(store, film: 1)).scenes).map { ($0.scene.sceneID!, $0.scene.heading) }
        let plan = StoryboardFolders.plan(scenes: scenes, folders: StoryboardFolders.folders(in: all))
        // Folder names match their headings, and the only loose board is the deliberate orphan.
        #expect(plan.renames.isEmpty, "\(plan.renames)")
        #expect(plan.missing.isEmpty)
        #expect(plan.orphans.map(\.name) == ["s099 ext-ferry-deck-day"])
        // s008 is left empty on purpose, to show the placeholder card; s011 is new since the lock.
        #expect(plan.unboarded == ["s011", "s008", "s013", "s014"]) // script order; the sequel has one board so far
        var shots: Set<String> = [], moves: Set<String> = []
        var clips = 0, sketches = 0
        let sequel = try Self.book(store, film: 1)
        for (id, folder) in plan.boarded {
            let text = try store.readText(at: folder.framesPath)
            let frames = try FramesFile(text: text)
            #expect(frames.text == text, "\(folder.name)/frames.json isn't in Slate's layout")
            #expect(frames.scene == id)
            let filmBook = book.sceneIDs.contains(id) ? book : sequel
            let scene = try #require(filmBook.scenes.first { $0.scene.sceneID == id })
            let parsed = try #require(filmBook.files.first { $0.path == scene.file }).parsed
            for frame in frames.frames {
                #expect(all.contains(folder.path + "/" + frame.file), "Missing \(folder.name)/\(frame.file)")
                let range = try #require(frame.scriptRange.flatMap(ScriptRange.init), "\(frame.file) has no script range")
                #expect(range.lines(in: scene.scene, of: parsed) != nil, "\(folder.name)/\(frame.file): \(range) not found")
                if let shot = frame.shot { shots.insert(shot) }
                if let move = frame.move { moves.insert(move) }
                if frame.isClip { clips += 1 }
                if all.contains(folder.path + "/" + StoryboardMedia.strokesFile(for: frame.file)) {
                    let url = try store.url(for: folder.path + "/" + StoryboardMedia.strokesFile(for: frame.file))
                    #expect(try !SketchStrokes(data: Data(contentsOf: url)).strokes.isEmpty)
                    sketches += 1
                }
            }
        }
        #expect(shots == Set(ShotSize.allCases.map(\.rawValue)))
        #expect(moves.count >= 6)
        #expect(clips == 1 && sketches == 1)
        #expect(StoryboardCover.firstImage(in: store.rootURL)?.lastPathComponent == "01.png")
    }

    @Test func animatic() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        let all = Self.paths(store)
        let book = try Self.book(store)
        let settings = try StoryboardSettings(text: store.readText(at: StoryboardFolders.settings))
        #expect(settings.score == "score.m4a")
        #expect(settings.pushIn)
        #expect(settings.guide == .scope)

        let plan = StoryboardFolders.plan(scenes: book.scenes.map { ($0.scene.sceneID!, $0.scene.heading) },
                                          folders: StoryboardFolders.folders(in: all))
        var boards: [String: (folder: String, frames: FramesFile)] = [:]
        for (id, board) in plan.boarded {
            boards[id] = (board.path, try FramesFile(text: store.readText(at: board.framesPath)))
        }
        let film = AnimaticTimeline.build(scenes: AnimaticScene.all(in: book, boards: boards), settings: settings)

        // Every image, clip and sound it plays is in the project.
        for path in film.mediaPaths { #expect(all.contains(path), "Missing \(path)") }
        #expect(film.audio.filter { $0.kind == .scratch }.count == 2)
        #expect(film.audio.filter { $0.kind == .score }.count == 1)
        // A scene runs its estimated time, unless every frame sets its own duration (s010 does: 4 s + 5 s).
        for scene in book.scenes {
            let id = scene.scene.sceneID!
            let length = film.segments.filter { $0.sceneID == id }.reduce(0) { $0 + $1.duration }
            let frames = boards[id]?.frames.frames ?? []
            if !frames.isEmpty, frames.allSatisfy({ $0.duration != nil }) {
                #expect(length == frames.compactMap(\.duration).reduce(0, +))
            } else {
                #expect(length >= scene.duration - 0.2, "\(id) runs \(length) s of \(scene.duration) s")
            }
        }
        #expect(boards["s010"]?.frames.frames.allSatisfy { $0.duration != nil } == true)
        let s008 = film.segments.filter { $0.sceneID == "s008" }
        #expect(s008.count == 1)
        if case .placeholder(let text)? = s008.first?.content { #expect(!text.isEmpty) } else { Issue.record("s008 isn't a placeholder") }
        // Push-in from the setting, pull-out from a frame's move.
        let motions = Set(film.segments.map(\.motion))
        #expect(motions == [.none, .pushIn, .pullOut])
        // Every scene with dialogue has subtitles inside its own time.
        let starts = film.sceneStarts
        for (index, scene) in book.scenes.enumerated() {
            let parsed = try #require(book.files.first { $0.path == scene.file }).parsed
            guard AnimaticTimeline.speeches(in: scene.scene, of: parsed).isEmpty == false else { continue }
            let start = starts[index].start, end = index + 1 < starts.count ? starts[index + 1].start : film.duration
            #expect(film.subtitles.contains { $0.start >= start - 0.01 && $0.end <= end + 0.01 }, "No subtitles in \(scene.scene.sceneID!)")
        }
    }

    @Test func production() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        let all = Self.paths(store)
        let film = Self.films(store)[0]
        let file = try ProductionFile(text: store.readText(at: film.productionPath))
        let acts = Films.actFiles(paths: all, in: film)
        let names = acts.map { ($0 as NSString).lastPathComponent }
        let parsed = try acts.map { ScriptParser.parse(try store.readText(at: $0)) }

        // Locked numbers: s011 is new (4A); the cut ferry scene s099 prints as 6 OMITTED.
        let revision = try #require(file.currentRevision)
        #expect(revision.color == .blue)
        let baselineFolder = try #require(file.currentBaselineFolder(in: film.revisionsFolder))
        let baseline = try names.map { (name: $0, text: try store.readText(at: baselineFolder + "/" + $0)) }
        let layout = ProductionLayout.make(files: zip(names, parsed).map { (name: $0, parsed: $1) }, production: file, baseline: baseline)
        #expect(layout.sceneLabels == ["1", "2", "3", "4", "4A", "5", "7", "8", "9", "10", "11"])
        #expect(layout.omitted.map(\.number) == ["6"])

        // Every locked page start is still found; the new scene pushes page 2 onto an A-page.
        for anchor in try #require(file.pages) {
            #expect(PageAnchors.resolve(anchor, files: parsed) != nil, "Page \(anchor.page) start not found")
        }
        let pages = Paginator(production: layout).paginate(parsed).pages
        #expect(pages.map(\.label).contains("2A"))
        #expect(!pages.contains { $0.omitted })
        let printed = pages.flatMap(\.rows).compactMap(\.line.sceneNumber)
        #expect(printed.contains("6") && printed.contains("4A"))

        // Revision marks: the new scene and two changed lines, on Blue pages.
        let marked = pages.flatMap(\.rows).filter(\.line.revised).map(\.line.text)
        #expect(marked.contains("INT. HARBOUR TICKET HUT - NIGHT"))
        #expect(marked.contains { $0.contains("The hard way.") })
        #expect(marked.contains { $0.contains("The bell goes") })
        #expect(pages.contains { $0.revision?.color == .blue })
        #expect(pages.contains { $0.revision == nil })

        // Reports cover every scene.
        let paginated = Paginator(production: layout).paginate(parsed)
        let rows = ProductionReport.scenes.rows(files: parsed, paginated: paginated, labels: layout.sceneLabels!, omitted: layout.omitted)
        #expect(rows.count == 12)
        #expect(rows[6] == ["6", "", "OMITTED", "", "", "", ""])
        #expect(ProductionReport.characters.rows(files: parsed, paginated: paginated, labels: layout.sceneLabels!).first?.first == "JUNO")
    }

    @Test func labelsAndSnapshots() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        let book = try Self.book(store)
        let colors = Dictionary(uniqueKeysWithValues: book.scenes.compactMap { scene in scene.scene.color.map { (scene.scene.sceneID!, $0) } })
        #expect(colors == ["s001": .blue, "s004": .red, "s005": .red, "s006": .red, "s007": .red, "s009": .red, "s010": .green])

        // The snapshot predates the ticket hut, and isn't an act file.
        let snapshots = ScriptSnapshot.all(in: store.rootURL, folder: Self.films(store)[0].snapshotsFolder)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.name == "Before the ticket hut")
        #expect(!Self.paths(store).contains { $0.contains(".snapshots") })
        let old = try snapshot.files()
        #expect(old.map(\.name) == ["01-act-one.md", "02-act-two.md", "03-act-three.md"])
        let now = try store.readText(at: "script/01 Tidewater/01-act-one.md")
        let rows = LineDiff.rows(old: old[0].text.components(separatedBy: "\n"), new: now.components(separatedBy: "\n"))
        // New since the snapshot (paired with s005's heading, which gained its colour label).
        #expect(rows.contains { $0.kind != .same && $0.new == "INT. HARBOUR TICKET HUT - NIGHT {#s011}" })
    }

    @Test func sagaOfTwoFilms() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        let films = Self.films(store)
        #expect(films.map(\.folder) == ["script/01 Tidewater", "script/02 Slack Water"])
        #expect(films.map(\.title) == ["Tidewater", "Slack Water"])
        #expect(TitlePage.parse(try store.readText(at: films[1].titlePagePath)).title == "Slack Water")

        // The sequel's scenes carry on the numbering: IDs are unique across the saga.
        let first = try Self.book(store, film: 0)
        let sequel = try Self.book(store, film: 1)
        #expect(sequel.scenes.compactMap(\.scene.sceneID) == ["s012", "s013", "s014"])
        #expect(first.sceneIDs.isDisjoint(with: sequel.sceneIDs))
        #expect(sequel.scenes.map(\.label) == ["1", "2", "3"])
        // Only the first film is locked for production.
        #expect(!Self.paths(store).contains(films[1].productionPath))

        // Boards, to-dos and links are shared by both films.
        let plan = StoryboardFolders.plan(scenes: (first.scenes + sequel.scenes).map { ($0.scene.sceneID!, $0.scene.heading) },
                                          folders: StoryboardFolders.folders(in: Self.paths(store)))
        #expect(plan.missing.isEmpty)
        #expect(plan.renames.isEmpty)
        #expect(plan.boarded["s012"]?.path == "storyboard/scenes/s012 ext-saltmarrow-harbour-dawn")
        let todos = MarginTodos.parse(try store.readText(at: "script/margin/todos.md"))
        #expect(todos.contains { $0.sceneID == "s013" })
        let indexed = IndexedFile.index(path: "script/02 Slack Water/01-act-one.md", text: try store.readText(at: "script/02 Slack Water/01-act-one.md"))
        #expect(indexed.links.contains { $0.link.target == "The Drowned Market" && $0.sceneID == "s014" })

        // Home adds them up.
        let summary = try #require(ProjectSummary.load(at: store.rootURL))
        #expect(summary.films == 2)
        #expect(summary.lengthText?.hasPrefix("2 films · ") == true)
    }

    @Test func searchAndTags() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        let graph = LinkIndex(store: store).graph
        let templates = NoteTemplates.builtIn
        let first = try Self.book(store, film: 0)
        let sequel = try Self.book(store, film: 1)

        var items = graph.notes.filter { $0.path.hasPrefix("universe/") }.map { note in SearchItems.note(note, template: NoteTemplates.matching(note.type, in: templates)) }
        items += SearchItems.script(first, film: "Tidewater", filmNumber: 1)
        items += SearchItems.script(sequel, film: "Slack Water", filmNumber: 2)
        let scenes = (first.scenes + sequel.scenes).map { ($0.scene.sceneID!, $0.scene.heading, Optional<String>.none, $0.scene.tags) }
        let index = TagIndex(notes: graph.notes, scenes: scenes)
        items += SearchItems.tags(index)

        let bangs = Bangs.all(templates: templates)
        func titles(_ text: String) -> [String] {
            SearchEngine.search(SearchQuery.parse(text, bangs: bangs), in: items).flatMap(\.items).map(\.title)
        }
        // Tags on characters and scenes.
        #expect(index.count("good") == 3)
        #expect(index.count("1987") == 4)
        #expect(titles("!t good protagonist") == ["Juno Hale"])
        #expect(Set(titles("!c #good")) == ["Juno Hale", "Ellis Hale", "Tobias Wren"], "\(titles("!c #good"))")
        #expect(titles("!s #storm").count == 2)
        #expect(titles("!s #mystery") == ["EXT. THE DROWNED MARKET - NIGHT"])
        #expect(titles("!c role:lead") == ["Juno Hale"])
        // Saga-wide scenes, and one film at a time.
        #expect(titles("!s film:2").count == 3)
        #expect(titles("!film slack !s").count == 3)
        #expect(titles("!s harbour").count >= 3)
        #expect(!titles("!cue juno").isEmpty)
        #expect(titles("!cue may").count == 2)
        // Tags never print.
        let pages = Paginator().paginate(sequel.files.map(\.parsed)).pages
        #expect(!pages.flatMap(\.rows).contains { $0.line.text.contains("mystery") })
    }

    @Test func headingIndex() throws {
        let folder = try TempFolder()
        let store = try Self.open(folder)
        let juno = Note(path: "universe/characters/juno-hale.md", text: try store.readText(at: "universe/characters/juno-hale.md"))
        let tree = HeadingTree.build(juno.headings, droppingTitle: juno.name)
        let ghost = try #require(tree.first { $0.heading.title == "Ghost" })
        #expect(ghost.children.map(\.heading.title) == ["1987", "Now"])
        #expect(ghost.children[0].children.map(\.key) == ["Ghost/1987/The bell"])
        let draft = HeadingTree.build(MarkdownOutline(parsing: try store.readText(at: ProjectLayout.draft)).headings)
        let act2 = try #require(HeadingTree.keys(draft).first { $0.hasSuffix("Act two: the rules") })
        #expect(HeadingTree.keys(draft).contains(act2 + "/The price of a turn"))
    }
}
