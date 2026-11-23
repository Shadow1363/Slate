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

    static func book(_ store: ProjectStore) throws -> ScriptBook {
        let acts = paths(store).filter { $0.hasPrefix("script/") && $0.split(separator: "/").count == 2 && $0 != "script/title-page.md" && $0.hasSuffix(".md") }
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
        let ids = try Self.book(store).sceneIDs
        let todos = MarginTodos.parse(try store.readText(at: "script/margin/todos.md"))
        #expect(todos.count == 6)
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
        let scenes = book.scenes.map { ($0.scene.sceneID!, $0.scene.heading) }
        let plan = StoryboardFolders.plan(scenes: scenes, folders: StoryboardFolders.folders(in: all))
        // Folder names match their headings, and the only loose board is the deliberate orphan.
        #expect(plan.renames.isEmpty, "\(plan.renames)")
        #expect(plan.missing.isEmpty)
        #expect(plan.orphans.map(\.name) == ["s099 ext-ferry-deck-day"])
        // s008 is left empty on purpose, to show the placeholder card; s011 is new since the lock.
        #expect(plan.unboarded == ["s011", "s008"]) // script order
        var shots: Set<String> = [], moves: Set<String> = []
        var clips = 0, sketches = 0
        for (id, folder) in plan.boarded {
            let text = try store.readText(at: folder.framesPath)
            let frames = try FramesFile(text: text)
            #expect(frames.text == text, "\(folder.name)/frames.json isn't in Slate's layout")
            #expect(frames.scene == id)
            let scene = try #require(book.scenes.first { $0.scene.sceneID == id })
            let parsed = try #require(book.files.first { $0.path == scene.file }).parsed
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
        let file = try ProductionFile(text: store.readText(at: ProductionFile.path))
        let acts = all.filter { $0.hasPrefix("script/") && $0.split(separator: "/").count == 2 && $0.hasSuffix(".md") && $0 != "script/title-page.md" }
        let names = acts.map { ($0 as NSString).lastPathComponent }
        let parsed = try acts.map { ScriptParser.parse(try store.readText(at: $0)) }

        // Locked numbers: s011 is new (4A); the cut ferry scene s099 prints as 6 OMITTED.
        let revision = try #require(file.currentRevision)
        #expect(revision.color == .blue)
        let baselineFolder = try #require(file.currentBaselineFolder)
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
}
