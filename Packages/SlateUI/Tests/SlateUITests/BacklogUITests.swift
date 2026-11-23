import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Backlog: script and storyboard")
struct BacklogUITests {
    private func makeWorkspace(acts: [String: String]) throws -> ScriptWorkspace {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SlateBacklog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try ProjectCreator.create(title: "Backlog", template: .blank, in: folder)
        try? FileManager.default.removeItem(at: root.appending(path: "script/script.md")) // the template's own
        for (name, text) in acts { try Data(text.utf8).write(to: root.appending(path: "script/" + name)) }
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let workspace = ScriptWorkspace(store: store)
        workspace.refreshFiles()
        return workspace
    }

    static let one = "# ACT ONE\n\nINT. KITCHEN - NIGHT {#s001}\n\nRain.\n\nEXT. ROOF - DAWN {#s002}\n\nWind.\n"
    static let two = "# ACT TWO\n\nINT. CELLAR - DAY {#s003}\n\nDust.\n"

    @Test func coloursMovesAndNewActs() throws {
        let workspace = try makeWorkspace(acts: ["01-act-one.md": Self.one, "02-act-two.md": Self.two])
        let roof = try #require(workspace.book.scenes.first { $0.scene.sceneID == "s002" })
        workspace.setColor(.green, for: roof)
        #expect(workspace.book.scenes.first { $0.scene.sceneID == "s002" }?.scene.color == .green)

        let moved = try #require(workspace.book.scenes.first { $0.scene.sceneID == "s002" })
        workspace.moveScene(moved, toFile: "script/02-act-two.md", at: 0)
        let book = workspace.book
        #expect(book.scenes.filter { $0.file == "script/01-act-one.md" }.map(\.scene.sceneID) == ["s001"])
        #expect(book.scenes.filter { $0.file == "script/02-act-two.md" }.map(\.scene.sceneID) == ["s002", "s003"])
        #expect(book.scenes.first { $0.scene.sceneID == "s002" }?.scene.color == .green)

        workspace.newActFile()
        #expect(workspace.scriptFiles.map(\.name) == ["01-act-one.md", "02-act-two.md", "03-act-three.md"])
        #expect(workspace.store.documents["script/03-act-three.md"]?.text == "# ACT THREE\n\n")
    }

    @Test func aCopiedActFileGetsNewSceneIDs() throws {
        let workspace = try makeWorkspace(acts: ["01-act-one.md": Self.one, "02-copy.md": Self.one])
        let ids = workspace.book.scenes.compactMap(\.scene.sceneID)
        #expect(Set(ids).count == ids.count)
        #expect(Array(ids.prefix(2)) == ["s001", "s002"])
    }

    @Test func snapshotsSaveAndRestore() throws {
        let workspace = try makeWorkspace(acts: ["01-act-one.md": Self.one])
        let snapshot = try workspace.saveSnapshot(name: "First", date: Date(timeIntervalSince1970: 1_795_400_000))
        #expect(workspace.snapshots.map(\.name) == ["First"])
        // Snapshots aren't act files.
        #expect(workspace.scriptFiles.map(\.name) == ["01-act-one.md"])

        let document = try #require(workspace.store.documents["script/01-act-one.md"])
        document.text = document.text.replacingOccurrences(of: "Rain.", with: "Snow.")
        try workspace.restore(snapshot)
        #expect(workspace.store.documents["script/01-act-one.md"]?.text.contains("Rain.") == true)
        #expect(workspace.snapshots.map(\.name).contains("Before restore"))
        let saved = try #require(workspace.snapshots.first { $0.name == "Before restore" })
        #expect(try saved.files().first?.text.contains("Snow.") == true)
    }

    @Test func focusAndTypewriterCommands() throws {
        let workspace = try makeWorkspace(acts: ["01-act-one.md": Self.one])
        let before = workspace.typewriter
        defer { workspace.typewriter = before }
        workspace.perform(.toggleFocus)
        #expect(workspace.focusMode)
        workspace.perform(.toggleTypewriter)
        #expect(workspace.typewriter == !before)
        #expect(UserDefaults.standard.bool(forKey: "script.typewriter") == !before)
        workspace.perform(.showSnapshots)
        #expect(workspace.showingSnapshots)
    }

    // MARK: Storyboard

    private func image(_ folder: URL, _ name: String) throws -> URL {
        let url = folder.appending(path: name)
        let image = NSImage(size: NSSize(width: 16, height: 9), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        try #require(image.pngData).write(to: url)
        return url
    }

    @Test func addingAndDeletingFramesUndo() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let folder = "storyboard/scenes/s014 int-kitchen-night"

        undo.beginUndoGrouping()
        let added = model.add(files: [try image(h.folder, "new.png")], toRow: "s014")
        undo.endUndoGrouping()
        #expect(added.map(\.file) == ["04.png"])
        #expect(model.rows[0].frames.count == 4)
        undo.undo()
        #expect(model.rows[0].frames.map(\.file) == ["01.png", "02.png", "03.png"])
        #expect(!FileManager.default.fileExists(atPath: h.store.rootURL.appending(path: folder + "/04.png").path))
        undo.redo()
        #expect(model.rows[0].frames.map(\.file) == ["01.png", "02.png", "03.png", "04.png"])
        #expect(FileManager.default.fileExists(atPath: h.store.rootURL.appending(path: folder + "/04.png").path))

        // ⌘A selects the row; deleting them all undoes in one step.
        model.select(FrameRef(folder: folder, file: "02.png"))
        model.selectAll()
        #expect(model.selected.count == 4)
        undo.beginUndoGrouping()
        model.delete(Array(model.selected))
        undo.endUndoGrouping()
        #expect(model.rows[0].frames.isEmpty)
        #expect(model.selected.isEmpty)
        undo.undo()
        #expect(model.rows[0].frames.map(\.file) == ["01.png", "02.png", "03.png", "04.png"])
        #expect(model.selected.count == 4)
        let caption = model.frame(FrameRef(folder: folder, file: "01.png"))?.caption
        #expect(caption == "Rain on the window") // details came back with the list

        model.select(FrameRef(folder: folder, file: "01.png"))
        model.toggleSelection(FrameRef(folder: folder, file: "03.png"))
        #expect(model.selected.count == 2)
        model.toggleSelection(FrameRef(folder: folder, file: "01.png"))
        #expect(model.selected == [FrameRef(folder: folder, file: "03.png")])
        #expect(model.selection == FrameRef(folder: folder, file: "03.png"))
    }
}
