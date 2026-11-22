import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Canvas model")
struct CanvasUITests {
    static let path = "universe/canvases/act-two.canvas"

    @Test func editsUndoAndWriteOnce() async throws {
        let h = try SessionHarness()
        let document = try h.store.document(at: Self.path)
        let original = document.text
        let model = CanvasModel(document: document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        #expect(model.canvas.nodes.count == 6)

        undo.beginUndoGrouping()
        model.addText(text: "New idea")
        undo.endUndoGrouping()
        #expect(model.canvas.nodes.count == 7)
        #expect(model.editingText == model.selection.first)
        // Not written until the debounce passes.
        #expect(document.text == original)
        model.flush()
        #expect(document.text.contains("\"text\":\"New idea\""))

        undo.undo()
        #expect(model.canvas.nodes.count == 6)
        model.flush()
        #expect(document.text == original)
        undo.redo()
        #expect(model.canvas.nodes.count == 7)
    }

    @Test func dragIsOneUndoStep() throws {
        let h = try SessionHarness()
        let model = CanvasModel(document: try h.store.document(at: Self.path))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let id = "n1a2b3c4d5e6f7a8"
        let start = model.canvas
        undo.beginUndoGrouping()
        for step in 1...5 {
            model.update(CanvasEditing.moving([id], by: Double(step) * 10, 0, in: start))
        }
        model.endInteraction("Move")
        undo.endUndoGrouping()
        #expect(model.canvas.node(id)?.rect.x == 430)
        undo.undo()
        #expect(model.canvas.node(id)?.rect.x == 380)
    }

    @Test func outsideEditsReloadAndUnchangedFilesStay() throws {
        let h = try SessionHarness()
        let document = try h.store.document(at: Self.path)
        let model = CanvasModel(document: document)
        model.selection = ["t1a2b3c4d5e6f7a8", "gone"]
        var canvas = model.canvas
        canvas.nodes.removeAll { $0.id == "l1a2b3c4d5e6f7a8" }
        document.text = canvas.text
        model.documentChanged()
        #expect(model.canvas.nodes.count == 5)
        #expect(model.selection == ["t1a2b3c4d5e6f7a8"])

        // A file written by another app, not changed in Slate, is never rewritten.
        let pretty = "{\n  \"nodes\": [],\n  \"edges\": []\n}\n"
        document.text = pretty
        model.documentChanged()
        model.flush()
        #expect(document.text == pretty)

        document.text = "{ not json"
        model.documentChanged()
        #expect(model.parseError != nil)
        model.addText(text: "ignored while broken")
        model.flush()
        #expect(document.text == "{ not json")
    }

    @Test func dropsMakeTheRightCards() throws {
        let h = try SessionHarness()
        let model = CanvasModel(document: try h.store.document(at: Self.path))
        let rect = CanvasRect(x: 0, y: 0, width: 200, height: 100)
        CanvasDrops.addPayload("slate-note:universe/rules/powers.md", at: rect, session: h.session, model: model)
        CanvasDrops.addPayload("slate-scene:script/script.md#s014", at: rect, session: h.session, model: model)
        CanvasDrops.addPayload("slate-heading:Act Two", at: rect, session: h.session, model: model)
        CanvasDrops.addPayload("https://example.com/page", at: rect, session: h.session, model: model)
        let added = model.canvas.nodes.suffix(4).map(\.card)
        #expect(added == [.note("universe/rules/powers.md"), .scene(file: "script/script.md", sceneID: "s014"), .text, .link("https://example.com/page")])
        #expect(model.canvas.nodes[model.canvas.nodes.count - 2].text == "## Act Two")

        // An image from outside the project is copied in.
        let image = h.folder.appending(path: "Outside Sketch.png")
        try FileManager.default.copyItem(at: h.store.rootURL.appending(path: "universe/canvases/images/station-sketch.png"), to: image)
        CanvasDrops.addFile(image, at: rect, session: h.session, model: model)
        #expect(model.canvas.nodes.last?.card == .image("universe/canvases/images/outside-sketch.png"))
        #expect(FileManager.default.fileExists(atPath: h.store.rootURL.appending(path: "universe/canvases/images/outside-sketch.png").path))
    }

    @Test func viewportZoomAndFit() throws {
        let h = try SessionHarness()
        let model = CanvasModel(document: try h.store.document(at: Self.path))
        model.viewSize = CGSize(width: 1000, height: 700)
        model.fit()
        let bounds = try #require(model.canvas.bounds)
        let box = model.viewRect(bounds)
        #expect(box.minX >= 59 && box.maxX <= 941)
        let anchor = CGPoint(x: 300, y: 200)
        let before = model.world(anchor)
        model.zoom(by: 2, around: anchor)
        let after = model.world(anchor)
        #expect(abs(before.x - after.x) < 0.001 && abs(before.y - after.y) < 0.001)
        model.zoom(by: 1000)
        #expect(model.scale == CanvasModel.maxScale)
        #expect(model.node(at: model.view(400, 0))?.id == "n1a2b3c4d5e6f7a8")
    }

    @Test func newCanvasOpensAndIsIndexed() throws {
        let h = try SessionHarness()
        h.session.createCanvas()
        #expect(h.session.universeSelection == "universe/canvases/untitled.canvas")
        #expect(try h.read("universe/canvases/untitled.canvas") == CanvasFile.empty)
        h.session.createCanvas()
        #expect(h.session.universeSelection == "universe/canvases/untitled-2.canvas")
        h.session.links.refresh()
        #expect(h.session.links.graph.backlinks(to: "universe/characters/mara-voss.md").contains { $0.kind == .canvas })
    }
}
