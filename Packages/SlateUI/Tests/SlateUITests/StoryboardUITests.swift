import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Storyboard model")
struct StoryboardUITests {
    static let kitchen = "storyboard/scenes/s014 int-kitchen-night"

    /// Adds a second scene to the sample script.
    private func addRoofScene(_ h: SessionHarness, heading: String = "EXT. ROOF - DAWN") throws {
        let document = try h.store.document(at: "script/script.md")
        document.text += "\n\(heading) {#s015}\n\nWind tears at the washing lines.\n"
        h.store.save(document)
        h.session.filesChanged()
    }

    private func image(_ folder: URL, _ name: String) throws -> URL {
        let url = folder.appending(path: name)
        let image = NSImage(size: NSSize(width: 32, height: 18), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        try #require(image.pngData).write(to: url)
        return url
    }

    private func undo() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    @Test func rowsFollowTheScript() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        #expect(model.rows.map(\.id) == ["s014"])
        #expect(model.rows[0].frames.map(\.file) == ["01.png", "02.png", "03.png"])
        #expect(model.durations(model.rows[0]).first == 3)
        try addRoofScene(h)
        #expect(model.rows.map(\.id) == ["s014", "s015"])
        #expect(model.rows[1].folder == nil)
        #expect(model.firstAction(of: model.rows[1].scene!) == "Wind tears at the washing lines.")
    }

    @Test func addingMakesTheFolderAndFramesFile() throws {
        let h = try SessionHarness()
        try addRoofScene(h)
        let model = h.session.storyboard
        let a = try image(h.folder, "a.png"), b = try image(h.folder, "b.png")
        let added = model.add(files: [a, b, h.folder.appending(path: "notes.txt")], toRow: "s015")
        #expect(added.map(\.file) == ["01.png", "02.png"])
        let folder = "storyboard/scenes/s015 ext-roof-dawn"
        #expect(added.first?.folder == folder)
        let frames = try FramesFile(text: h.store.readText(at: folder + "/frames.json"))
        #expect(frames.scene == "s015")
        #expect(frames.frames.map(\.file) == ["01.png", "02.png"])
        #expect(model.selection == added.first)
        // A file dropped into the folder by hand shows up at the end.
        try FileManager.default.copyItem(at: a, to: h.store.url(for: folder + "/zz-extra.png"))
        h.store.rescan()
        h.session.filesChanged()
        #expect(model.row("s015")?.frames.map(\.file) == ["01.png", "02.png", "zz-extra.png"])
        // Inserting at a position.
        let c = try image(h.folder, "c.png")
        model.add(files: [c], toRow: "s014", at: 0)
        #expect(model.row("s014")?.frames.first?.file == "04.png")
    }

    @Test func reorderAndMetadataUndo() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        let undo = undo()
        model.undoManager = undo
        let first = FrameRef(folder: Self.kitchen, file: "01.png")
        undo.beginUndoGrouping()
        model.move(first, toRow: "s014", at: 3)
        undo.endUndoGrouping()
        #expect(model.row("s014")?.frames.map(\.file) == ["02.png", "03.png", "01.png"])
        undo.beginUndoGrouping()
        model.update(first, "Edit Caption") { $0.caption = "Rain, harder" }
        undo.endUndoGrouping()
        #expect(model.frame(first)?.caption == "Rain, harder")
        #expect(try h.store.document(at: Self.kitchen + "/frames.json").text.contains("Rain, harder"))
        undo.undo()
        #expect(model.frame(first)?.caption == "Rain on the window")
        undo.undo()
        #expect(model.row("s014")?.frames.map(\.file) == ["01.png", "02.png", "03.png"])
        undo.redo()
        #expect(model.row("s014")?.frames.first?.file == "02.png")
    }

    @Test func movingBetweenScenesMovesFilesAndUndoes() throws {
        let h = try SessionHarness()
        try addRoofScene(h)
        let model = h.session.storyboard
        let undo = undo()
        model.undoManager = undo
        model.add(files: [try image(h.folder, "a.png")], toRow: "s015")
        // The sketch moves with its strokes, renamed because 01.png… is taken.
        undo.beginUndoGrouping()
        model.move(FrameRef(folder: Self.kitchen, file: "03.png"), toRow: "s015", at: 0)
        undo.endUndoGrouping()
        let roof = "storyboard/scenes/s015 ext-roof-dawn"
        #expect(model.row("s015")?.frames.map(\.file) == ["03.png", "01.png"])
        #expect(h.session.exists(roof + "/03.strokes.json"))
        #expect(!h.session.exists(Self.kitchen + "/03.png"))
        #expect(model.row("s014")?.frames.count == 2)
        undo.undo()
        #expect(model.row("s014")?.frames.map(\.file) == ["01.png", "02.png", "03.png"])
        #expect(h.session.exists(Self.kitchen + "/03.strokes.json"))
    }

    @Test func deleteSendsFilesToTheTrash() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        let ref = FrameRef(folder: Self.kitchen, file: "03.png")
        model.select(ref)
        model.delete(ref)
        #expect(model.selection == nil)
        #expect(!h.session.exists(Self.kitchen + "/03.png"))
        #expect(!h.session.exists(Self.kitchen + "/03.strokes.json"))
        #expect(model.row("s014")?.frames.count == 2)
    }

    @Test func missingScenesReattachAndOrphan() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        // Retag the kitchen scene: its board loses its scene.
        let document = try h.store.document(at: "script/script.md")
        document.text = document.text.replacingOccurrences(of: "{#s014}", with: "{#s020}")
        h.session.filesChanged()
        #expect(model.rows.map(\.kind) == [.scene, .missing])
        let missing = try #require(model.rows.last?.folder)
        // Reattach: the folder takes the new scene's name, and frames.json its ID.
        model.reattach(missing, toScene: "s020")
        let moved = "storyboard/scenes/s020 int-kitchen-night"
        #expect(model.rows.map(\.kind) == [.scene])
        #expect(try FramesFile(text: h.store.readText(at: moved + "/frames.json")).scene == "s020")
        // Gone again: tidying on close moves it to orphans/, and it can come back from there.
        document.text = document.text.replacingOccurrences(of: "{#s020}", with: "{#s021}")
        h.session.filesChanged()
        model.tidyFolders(moveMissing: true)
        #expect(model.orphanRows.map(\.title) == ["s020 int-kitchen-night"])
        model.reattach(try #require(model.orphanRows.first?.folder), toScene: "s021")
        #expect(model.orphanRows.isEmpty)
        #expect(model.row("s021")?.frames.count == 3)
    }

    @Test func tidyRenamesFoldersButNeverOrphansAnEmptyScript() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        let document = try h.store.document(at: "script/script.md")
        document.text = document.text.replacingOccurrences(of: "INT. KITCHEN - NIGHT", with: "INT. PANTRY - NIGHT")
        h.session.filesChanged()
        model.tidyFolders(moveMissing: true)
        #expect(model.row("s014")?.folder?.name == "s014 int-pantry-night")
        // With no scenes at all (a script that failed to load), nothing is moved.
        document.text = ""
        h.session.filesChanged()
        model.tidyFolders(moveMissing: true)
        #expect(h.session.exists("storyboard/scenes/s014 int-pantry-night/frames.json"))
    }

    @Test func scriptAndFramesHighlightEachOther() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        let first = FrameRef(folder: Self.kitchen, file: "01.png")
        model.select(first)
        #expect(h.session.script.frameHighlight == FrameHighlight(sceneID: "s014", range: "action-1"))
        // The caret on the action line outlines the two frames that cover it.
        let text = try h.store.readText(at: "script/script.md")
        let location = (text as NSString).range(of: "Rain hammers").location
        h.session.script.caret = ScriptCaret(file: "script/script.md", location: location, kind: .action, sceneIndex: 0)
        #expect(model.framesAtCaret == [first, FrameRef(folder: Self.kitchen, file: "02.png")])
        // "Show Frames in Storyboard" from the script.
        let parsed = ScriptParser.parse(text)
        StoryboardActions.showFrames(sceneID: "s014", line: parsed.lineIndex(containing: location), session: h.session)
        #expect(h.session.area == .storyboard)
        #expect(model.selection == first)
        model.select(nil)
        #expect(h.session.script.frameHighlight == nil)
    }

    @Test func sketchesSaveAndReopen() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        var sketch = SketchStrokes(guide: .scope)
        sketch.strokes = [.init(grey: 0.1, width: 0.005, points: [[0.1, 0.5, 1], [0.9, 0.5, 0.4]]),
                          .init(grey: 1, width: 0.01, erase: true, points: [[0.5, 0.5, 1]])]
        let png = try #require(SketchRenderer.png(sketch, pixelWidth: 480))
        let rendered = try #require(NSBitmapImageRep(data: png))
        // Cropped to the 2.39:1 guide.
        #expect(rendered.pixelsWide == 480 && rendered.pixelsHigh == 201)
        model.saveSketch(sketch, png: png, target: .init(sceneID: "s014", file: nil))
        let ref = FrameRef(folder: Self.kitchen, file: "04.png")
        #expect(model.row("s014")?.frames.last?.file == "04.png")
        #expect(try model.strokes(for: ref) == SketchStrokes(data: sketch.data))
        // Editing saves over the same files.
        sketch.strokes.removeLast()
        model.saveSketch(sketch, png: try #require(SketchRenderer.png(sketch)), target: .init(sceneID: "s014", file: "04.png"))
        #expect(model.strokes(for: ref)?.strokes.count == 1)
        #expect(model.row("s014")?.frames.count == 4)
    }

    @Test func clipsGetAPosterAndALength() async throws {
        let h = try SessionHarness()
        let clip = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Showcase/Tidewater/storyboard/scenes/s003 int-the-lighthouse-lamp-room-night/02.mov")
        let model = h.session.storyboard
        let ref = try #require(model.add(files: [clip], toRow: "s014").first)
        #expect(ref.file == "04.mov")
        #expect(model.frame(ref)?.isClip == true)
        // The length arrives first, then the poster; both load in the background.
        for _ in 0..<100 where model.thumbnails.thumbnail(for: ref.path, url: model.url(ref)) == nil
            || model.thumbnails.clipLength(for: ref.path) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let length = try #require(model.thumbnails.clipLength(for: ref.path))
        #expect(abs(length - 3) < 0.1)
        #expect(model.thumbnails.thumbnail(for: ref.path, url: model.url(ref)) != nil)
        // An untrimmed clip plays its full length.
        #expect(abs((model.durations(try #require(model.row("s014"))).last ?? 0) - 3) < 0.1)
    }

    @Test func homeCoverIsTheFirstFrame() throws {
        let h = try SessionHarness()
        #expect(ProjectSummary.load(at: h.store.rootURL)?.cover?.lastPathComponent == "01.png")
    }
}
