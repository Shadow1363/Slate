import Foundation
import Testing
@testable import SlateCore

@Suite("Map")
struct MapTests {
    static let path = "universe/maps/city.map.json"

    static func sample() throws -> String {
        try String(contentsOf: Fixtures.sampleProject.appending(path: path), encoding: .utf8)
    }

    @Test func readsTheSample() throws {
        let map = try MapFile(text: Self.sample())
        #expect(map.image == "city.png")
        #expect(map.layers.map(\.name) == ["1998", "2031"])
        #expect(map.pins.count == 2)
        #expect(map.pins[0].points == [MapPoint(x: 0.42, y: 0.31)])
        #expect(map.pins[0].note == "l-51c0")
        #expect(map.pins[0].scenes == ["s014"])
        #expect(map.pins[0].layer == nil)
        #expect(map.regions[0].points.count == 4)
        #expect(map.paths[0].kind == .path)
        #expect(map.item("w-ch01")?.title == "The chase")
        #expect(MapFile.imagePath("city.png", mapPath: Self.path) == "universe/maps/city.png")
        #expect(MapFile.imagePath("../art/city.png", mapPath: Self.path) == "universe/art/city.png")
    }

    @Test func unchangedFilesRoundTripByteForByte() throws {
        let text = try Self.sample()
        #expect(try MapFile(text: text).text == text)
        #expect(try MapFile(text: MapFile.empty).text == MapFile.empty)
        #expect(try MapFile(text: MapFile.empty).image == nil)
        #expect(MapFile().aspect == MapFile.defaultAspect)
    }

    @Test func editsKeepUnknownKeysAndRoundCoordinates() throws {
        var map = try MapFile(text: Self.sample())
        map = MapEditing.moving(["p-st01"], by: 0.012345, 0, in: map)
        #expect(map.pins[0].points[0].x == 0.4323)
        #expect(map.text.contains("\"studio\": {\"note\": \"Unknown keys like this one must survive a save.\"}"))
        #expect(map.text.contains("\"x\": 0.4323"))
        // Only the changed coordinate is rewritten.
        #expect(map.pins[0].object["y"] == .number("0.31"))
    }

    @Test func movingKeepsShapesOnTheMap() throws {
        let map = try MapFile(text: Self.sample())
        let moved = MapEditing.moving(["r-ot01"], by: -0.5, 0, in: map)
        let xs = moved.regions[0].points.map(\.x)
        #expect(xs.min() == 0)
        // The shape keeps its form: every corner moved by the same amount.
        #expect(abs((xs[1] - xs[0]) - 0.22) < 1e-9)
        let pinned = MapEditing.movingPoint(0, of: "p-kt01", to: MapPoint(x: 1.4, y: -1), in: map)
        #expect(pinned.pins[1].points[0] == MapPoint(x: 1, y: 0))
    }

    @Test func addingAndRemoving() throws {
        var map = MapFile()
        let id = MapEditing.newID(.region, in: map)
        #expect(id.hasPrefix("r-"))
        let (layered, layer) = MapEditing.addingLayer("1998", to: map)
        map = MapEditing.adding(MapItem(kind: .region, id: id, title: "Docks",
                                        points: [MapPoint(x: 0, y: 0), MapPoint(x: 1, y: 0), MapPoint(x: 0, y: 1)], layer: layer), to: layered)
        #expect(map.regions.count == 1)
        #expect(map.regions[0].layer == layer)
        map = MapEditing.removingLayer(layer, from: map)
        #expect(map.regions[0].layer == nil)
        #expect(map.layers.isEmpty)
        map = MapEditing.removing([id], from: map)
        #expect(map.items.isEmpty)
        map.image = "harbour.png"
        #expect(map.text.hasPrefix("{\n  \"image\": \"harbour.png\""))
    }

    @Test func geometry() {
        let square = [MapPoint(x: 0.2, y: 0.2), MapPoint(x: 0.6, y: 0.2), MapPoint(x: 0.6, y: 0.6), MapPoint(x: 0.2, y: 0.6)]
        #expect(MapGeometry.contains(square, MapPoint(x: 0.4, y: 0.4)))
        #expect(!MapGeometry.contains(square, MapPoint(x: 0.7, y: 0.4)))
        #expect(!MapGeometry.contains(Array(square.prefix(2)), MapPoint(x: 0.4, y: 0.2)))
        let line = [MapPoint(x: 0, y: 0.5), MapPoint(x: 1, y: 0.5)]
        #expect(abs(MapGeometry.distance(from: MapPoint(x: 0.3, y: 0.6), to: line) - 0.1) < 1e-9)
        #expect(abs(MapGeometry.distance(from: MapPoint(x: 1.1, y: 0.5), to: line, aspect: 2) - 0.2) < 1e-9)
        #expect(MapGeometry.centre(square) == MapPoint(x: 0.4, y: 0.4))
    }

    @Test func pinsLinkToNotes() throws {
        let file = IndexedFile.index(path: Self.path, text: try Self.sample())
        #expect(file.links.map(\.kind) == [.map])
        let graph = LinkGraph(files: [
            file,
            IndexedFile.index(path: "universe/locations/the-station.md", text: "---\nid: l-51c0\nname: The Station\n---\n"),
        ])
        #expect(graph.backlinks(to: "universe/locations/the-station.md").map(\.snippet) == ["“The Station” on this map"])
    }
}
