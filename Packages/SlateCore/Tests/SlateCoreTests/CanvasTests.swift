import Foundation
import Testing
@testable import SlateCore

@Suite("Canvas file")
struct CanvasFileTests {
    static let path = "universe/canvases/act-two.canvas"

    static func sample() throws -> String {
        try String(contentsOf: Fixtures.sampleProject.appending(path: path), encoding: .utf8)
    }

    @Test func readsEveryCardType() throws {
        let canvas = try CanvasFile(text: Self.sample())
        #expect(canvas.nodes.map(\.card) == [
            .group, .text, .note("universe/characters/mara-voss.md"), .scene(file: "script/script.md", sceneID: "s014"),
            .image("universe/canvases/images/station-sketch.png"), .link("https://jsoncanvas.org"),
        ])
        #expect(canvas.nodes[1].text == "## Why the key matters\n\nMara must **not** open it. See [[The Brass Key]].")
        #expect(canvas.nodes[0].label == "The kitchen night")
        #expect(canvas.nodes[0].color == "4")
        #expect(canvas.nodes[2].rect == CanvasRect(x: 380, y: -20, width: 280, height: 200))
        #expect(canvas.edges.count == 2)
        #expect(canvas.edges[0].label == "drives")
        #expect(canvas.edges[0].fromSide == .right)
        #expect(canvas.edges[0].toArrow)
        #expect(!canvas.edges[1].toArrow)
        #expect(!canvas.edges[0].fromArrow)
    }

    @Test func unchangedFilesRoundTripByteForByte() throws {
        let text = try Self.sample()
        #expect(try CanvasFile(text: text).text == text)
        #expect(try CanvasFile(text: CanvasFile.empty).text == CanvasFile.empty)
    }

    @Test func unknownKeysSurviveEdits() throws {
        var canvas = try CanvasFile(text: Self.sample())
        canvas = CanvasEditing.moving(["n1a2b3c4d5e6f7a8"], by: 20, 0, in: canvas)
        let text = canvas.text
        #expect(text.contains("{\"id\":\"n1a2b3c4d5e6f7a8\",\"type\":\"file\",\"file\":\"universe/characters/mara-voss.md\",\"x\":400,\"y\":-20,\"width\":280,\"height\":200,\"styleAttributes\":{}}"))
        let withTop = try CanvasFile(text: "{\"nodes\":[],\"edges\":[],\"version\":\"1.0\",\"meta\":{\"b\":1,\"a\":[1.5,\"\\u00e9\\n\"]}}")
        #expect(withTop.text == "{\n\t\"nodes\":[],\n\t\"edges\":[],\n\t\"version\":\"1.0\",\n\t\"meta\":{\"b\":1,\"a\":[1.5,\"é\\n\"]}\n}")
    }

    @Test func readsOtherAppsAndRejectsJunk() throws {
        // Pretty-printed with spaces, as another app might write it.
        let other = """
        {
          "nodes": [
            { "id": "a", "type": "text", "text": "Hi 😀", "x": 0, "y": 0, "width": 100, "height": 50 },
            { "id": "b", "type": "portal", "x": 10.5, "y": 0, "width": 100, "height": 50 }
          ],
          "edges": []
        }
        """
        let canvas = try CanvasFile(text: other)
        #expect(canvas.nodes[0].text == "Hi 😀")
        #expect(canvas.nodes[1].card == .unknown("portal"))
        #expect(canvas.nodes[1].rect.x == 10.5)
        #expect(try CanvasFile(text: "").nodes.isEmpty)
        #expect(throws: OrderedJSON.ParseError.self) { try CanvasFile(text: "{\"nodes\":[") }
        #expect(throws: OrderedJSON.ParseError.self) { try CanvasFile(text: "[1,2]") }
    }
}

@Suite("Canvas editing")
struct CanvasEditingTests {
    func board() -> CanvasFile {
        var canvas = CanvasFile()
        canvas.nodes = [
            CanvasNode(id: "a", kind: .text, rect: .init(x: 0, y: 0, width: 100, height: 50)),
            CanvasNode(id: "b", kind: .text, rect: .init(x: 300, y: 40, width: 100, height: 80)),
            CanvasNode(id: "c", kind: .text, rect: .init(x: 1000, y: 10, width: 200, height: 50)),
        ]
        return canvas
    }

    @Test func addRemoveAndConnect() throws {
        var canvas = board()
        let (connected, edge) = try #require(CanvasEditing.connecting("a", to: "b", in: canvas))
        canvas = connected
        #expect(canvas.edges.first?.fromSide == .right)
        #expect(canvas.edges.first?.toSide == .left)
        #expect(CanvasEditing.sides(from: .init(x: 0, y: 0, width: 10, height: 10), to: .init(x: 0, y: 300, width: 10, height: 10)) == (.bottom, .top))
        #expect(CanvasEditing.connecting("a", to: "a", in: canvas) == nil)
        canvas = CanvasEditing.removing(["b"], from: canvas)
        #expect(canvas.nodes.map(\.id) == ["a", "c"])
        #expect(!canvas.edges.contains { $0.id == edge })
        let id = CanvasEditing.newID(in: canvas)
        #expect(id.count == 16)
        let group = CanvasEditing.group("G", at: .init(x: -10, y: -10, width: 50, height: 50), in: canvas)
        #expect(CanvasEditing.adding(group, to: canvas).nodes.first?.kind == .group)
    }

    @Test func groupsCarryTheirCards() throws {
        let (grouped, groupID) = try #require(CanvasEditing.grouping(["a", "b"], label: "Pair", in: board()))
        #expect(grouped.nodes.first?.id == groupID)
        #expect(Set(CanvasEditing.members(of: groupID, in: grouped)) == ["a", "b"])
        let carried = CanvasEditing.carried([groupID], in: grouped)
        #expect(carried == [groupID, "a", "b"])
        let moved = CanvasEditing.moving(carried, by: 15, 5, in: grouped, snapToGrid: true)
        // Snapping moves the lead node onto the grid and the rest by the same amount.
        let group = try #require(moved.node(groupID)).rect
        #expect(group.x.truncatingRemainder(dividingBy: 20) == 0)
        #expect(moved.node("a")!.rect.x - grouped.node("a")!.rect.x == group.x - grouped.node(groupID)!.rect.x)
        #expect(moved.node("c")!.rect == grouped.node("c")!.rect)
    }

    @Test func alignAndDistribute() {
        let aligned = CanvasEditing.aligning(["a", "b", "c"], .top, in: board())
        #expect(aligned.nodes.map(\.rect.y) == [0, 0, 0])
        let right = CanvasEditing.aligning(["a", "b"], .right, in: board())
        #expect(right.nodes.prefix(2).map(\.rect.maxX) == [400, 400])
        let centred = CanvasEditing.aligning(["a", "b"], .centerY, in: board())
        #expect(centred.node("a")!.rect.midY == centred.node("b")!.rect.midY)
        let spread = CanvasEditing.distributing(["a", "b", "c"], .horizontal, in: board())
        let xs = spread.nodes.map(\.rect)
        #expect(xs[1].x - xs[0].maxX == xs[2].x - xs[1].maxX)
        #expect(xs[0].x == 0)
        #expect(xs[2].x == 1000)
    }

    @Test func resizeSnapFrontAndMarquee() {
        var canvas = CanvasEditing.resizing("a", to: .init(x: 3, y: 7, width: 133, height: 5), in: board(), snapToGrid: true)
        #expect(canvas.node("a")!.rect == CanvasRect(x: 0, y: 0, width: 140, height: 30))
        canvas = CanvasEditing.bringingToFront(["a"], in: canvas)
        #expect(canvas.nodes.last?.id == "a")
        #expect(Set(CanvasEditing.nodes(in: .init(x: -10, y: -10, width: 350, height: 100), of: canvas)) == ["a", "b"])
        #expect(CanvasEditing.snap(29) == 20)
        #expect(CanvasEditing.snap(31) == 40)
    }
}

@Suite("Canvas links")
struct CanvasLinkTests {
    @Test func canvasesAreBacklinks() throws {
        let file = IndexedFile.index(path: CanvasFileTests.path, text: try CanvasFileTests.sample())
        #expect(file.links.map(\.link.target) == ["The Brass Key", "universe/characters/mara-voss.md"])
        #expect(file.links.allSatisfy { $0.kind == .canvas })
        let graph = LinkGraph(files: [
            file,
            IndexedFile.index(path: "universe/characters/mara-voss.md", text: "---\nname: Mara Voss\n---\n"),
            IndexedFile.index(path: "universe/items/the-brass-key.md", text: "---\nname: The Brass Key\n---\n"),
        ])
        #expect(graph.backlinks(to: "universe/characters/mara-voss.md").map(\.kind) == [.canvas])
        #expect(graph.backlinks(to: "universe/items/the-brass-key.md").count == 1)
        #expect(graph.resolve("universe/characters/mara-voss.md")?.path == "universe/characters/mara-voss.md")
    }

    @MainActor
    @Test func renameMovesNoteCards() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let index = LinkIndex(store: store)
        let plan = try #require(RenameRefactor.plan(
            renaming: "universe/characters/mara-voss.md", to: "Mara Kell", in: index.graph,
            existingPaths: Set(store.files.values.flatMap { $0 }.map(\.relativePath))
        ))
        #expect(plan.edits.contains { $0.path == CanvasFileTests.path && $0.replacement == "universe/characters/mara-kell.md" })
        try RenameRefactor.apply(plan, updateLinks: true, store: store)
        let canvas = try CanvasFile(text: folder.read("SampleProject/" + CanvasFileTests.path))
        #expect(canvas.node("n1a2b3c4d5e6f7a8")?.file == "universe/characters/mara-kell.md")
    }

    @Test func titleNotesKeepTheirKeyOnRename() throws {
        // RenameRefactor writes `title:` for notes named that way.
        let text = "---\ntitle: Tom\ninfobox: Character\n---\n"
        let fields = try Frontmatter.fields(in: text)
        #expect(fields.contains { $0.key == "title" })
    }
}
