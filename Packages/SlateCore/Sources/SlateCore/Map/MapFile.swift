import Foundation

/// A point on a map, normalised 0–1 against the base image (x right, y down),
/// so a sharper copy of the same image keeps every pin in place.
public struct MapPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var clamped: MapPoint {
        MapPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Four decimal places: under a pixel on a 10,000-pixel map, and short to read.
    var json: OrderedJSON {
        .array([.number(Self.round(x)), .number(Self.round(y))])
    }

    static func round(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    init?(json: OrderedJSON) {
        guard let items = json.array, items.count >= 2, let x = items[0].double, let y = items[1].double else { return nil }
        self.init(x: x, y: y)
    }
}

/// A layer that can be shown or hidden (`1998`, `2031`).
public struct MapLayer: Sendable, Equatable, Identifiable {
    public var object: JSONObject

    public init(object: JSONObject) { self.object = object }

    public init(id: String, name: String) {
        object = JSONObject([("id", .string(id)), ("name", .string(name))])
    }

    public var id: String { object.text("id") ?? "" }

    public var name: String {
        get { object.text("name") ?? id }
        set { object.setText("name", newValue) }
    }
}

/// A pin, region (closed polygon) or path (open line).
public struct MapItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case pin, region, path

        /// The list it's kept in.
        public var key: String {
            switch self {
            case .pin: "pins"
            case .region: "regions"
            case .path: "paths"
            }
        }

        public var title: String { rawValue.capitalized }
    }

    public let kind: Kind
    public var object: JSONObject

    public init(kind: Kind, object: JSONObject) {
        self.kind = kind
        self.object = object
    }

    /// A new item: id, title, then its geometry.
    public init(kind: Kind, id: String, title: String, points: [MapPoint], layer: String? = nil) {
        self.kind = kind
        object = JSONObject([("id", .string(id)), ("title", .string(title))])
        if kind == .pin, let point = points.first {
            object["x"] = .number(MapPoint.round(point.x))
            object["y"] = .number(MapPoint.round(point.y))
        } else {
            object["points"] = .array(points.map(\.json))
        }
        object.setText("layer", layer)
    }

    public var id: String { object.text("id") ?? "" }

    public var title: String {
        get { object.text("title") ?? "" }
        set { object.setText("title", newValue) }
    }

    /// A pin's one point, or a region's or path's corners.
    public var points: [MapPoint] {
        get {
            if kind == .pin {
                return [MapPoint(x: object["x"]?.double ?? 0.5, y: object["y"]?.double ?? 0.5)]
            }
            return (object["points"]?.array ?? []).compactMap(MapPoint.init(json:))
        }
        set {
            if kind == .pin {
                guard let point = newValue.first else { return }
                if point.x != object["x"]?.double { object["x"] = .number(MapPoint.round(point.x)) }
                if point.y != object["y"]?.double { object["y"] = .number(MapPoint.round(point.y)) }
            } else {
                object["points"] = .array(newValue.map(\.json))
            }
        }
    }

    /// nil: always shown, whatever layers are hidden.
    public var layer: String? {
        get { object.text("layer") }
        set { object.setText("layer", newValue) }
    }

    /// The location note: a note `id`, a path, or a name.
    public var note: String? {
        get { object.text("note") }
        set { object.setText("note", newValue) }
    }

    /// Scene IDs (`s014`) set here.
    public var scenes: [String] {
        get { object.strings("scenes") }
        set { object.setStrings("scenes", newValue) }
    }

    /// `"1"`–`"6"` (the canvas palette) or a hex colour.
    public var color: String? {
        get { object.text("color") }
        set { object.setText("color", newValue) }
    }
}

/// A `*.map.json` file. Keys Slate doesn't know are kept, in order.
public struct MapFile: TextBackedFile {
    public var root: JSONObject
    public var layers: [MapLayer]
    public var pins: [MapItem]
    public var regions: [MapItem]
    public var paths: [MapItem]

    public static let suffix = ".map.json"
    /// Width ÷ height of a blank grid map.
    public static let defaultAspect = 1.5

    public init() {
        root = JSONObject([("image", .null)])
        layers = []
        pins = []
        regions = []
        paths = []
    }

    public init(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.init()
            return
        }
        guard case .object(let root) = try OrderedJSON.parse(text) else {
            throw OrderedJSON.ParseError(message: "a map must be a JSON object", offset: 0)
        }
        self.init(root: root)
    }

    /// Reads the lists out of a parsed top-level object.
    public init(root: JSONObject) {
        func list(_ key: String) -> [JSONObject] { (root[key]?.array ?? []).compactMap(\.object) }
        self.root = root
        layers = list("layers").map(MapLayer.init(object:))
        pins = list("pins").map { MapItem(kind: .pin, object: $0) }
        regions = list("regions").map { MapItem(kind: .region, object: $0) }
        paths = list("paths").map { MapItem(kind: .path, object: $0) }
    }

    public var composed: JSONObject {
        var object = root
        object["layers"] = .array(layers.map { .object($0.object) })
        object["pins"] = .array(pins.map { .object($0.object) })
        object["regions"] = .array(regions.map { .object($0.object) })
        object["paths"] = .array(paths.map { .object($0.object) })
        return object
    }

    public var text: String {
        OrderedJSON.object(composed).pretty() + "\n"
    }

    public static func == (lhs: MapFile, rhs: MapFile) -> Bool {
        lhs.composed == rhs.composed
    }

    public static var empty: String { MapFile().text }

    /// The base image, relative to the map file's folder; nil for a blank grid.
    public var image: String? {
        get { root.text("image") }
        set { root["image"] = newValue.flatMap { $0.isEmpty ? nil : .string($0) } ?? .null }
    }

    /// Width ÷ height, for a blank grid (an image uses its own size).
    public var aspect: Double {
        get { root["aspect"]?.double.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultAspect }
        set { root["aspect"] = .number(newValue) }
    }

    /// Pins, then paths, then regions: the order hits are tested in (top first).
    public var items: [MapItem] { pins + paths + regions }

    public func item(_ id: String) -> MapItem? {
        items.first { $0.id == id }
    }

    var usedIDs: Set<String> {
        Set(items.map(\.id) + layers.map(\.id))
    }

    /// The image's path from the project root, given the map file's path.
    public static func imagePath(_ image: String, mapPath: String) -> String {
        guard !image.hasPrefix("/") else { return image }
        var parts = (mapPath as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for part in image.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }
}

/// Edits on a map, as pure functions of `MapFile`.
public enum MapEditing {
    public static func newID(_ kind: MapItem.Kind, in file: MapFile) -> String {
        let prefix = switch kind {
        case .pin: "p"
        case .region: "r"
        case .path: "w"
        }
        return shortID(prefix, used: file.usedIDs)
    }

    public static func adding(_ item: MapItem, to file: MapFile) -> MapFile {
        var copy = file
        switch item.kind {
        case .pin: copy.pins.append(item)
        case .region: copy.regions.append(item)
        case .path: copy.paths.append(item)
        }
        return copy
    }

    public static func updating(_ id: String, in file: MapFile, _ change: (inout MapItem) -> Void) -> MapFile {
        var copy = file
        if let index = copy.pins.firstIndex(where: { $0.id == id }) {
            change(&copy.pins[index])
        } else if let index = copy.regions.firstIndex(where: { $0.id == id }) {
            change(&copy.regions[index])
        } else if let index = copy.paths.firstIndex(where: { $0.id == id }) {
            change(&copy.paths[index])
        }
        return copy
    }

    public static func removing(_ ids: Set<String>, from file: MapFile) -> MapFile {
        var copy = file
        copy.pins.removeAll { ids.contains($0.id) }
        copy.regions.removeAll { ids.contains($0.id) }
        copy.paths.removeAll { ids.contains($0.id) }
        return copy
    }

    /// Moves whole items, keeping them on the map.
    public static func moving(_ ids: Set<String>, by dx: Double, _ dy: Double, in file: MapFile) -> MapFile {
        guard dx != 0 || dy != 0 else { return file }
        var copy = file
        for id in ids {
            copy = updating(id, in: copy) { item in
                let points = item.points
                // Shift by the most every corner can take, so the shape keeps its form.
                let sx = min(max(dx, -(points.map(\.x).min() ?? 0)), 1 - (points.map(\.x).max() ?? 1))
                let sy = min(max(dy, -(points.map(\.y).min() ?? 0)), 1 - (points.map(\.y).max() ?? 1))
                item.points = points.map { MapPoint(x: $0.x + sx, y: $0.y + sy) }
            }
        }
        return copy
    }

    public static func movingPoint(_ index: Int, of id: String, to point: MapPoint, in file: MapFile) -> MapFile {
        updating(id, in: file) { item in
            var points = item.points
            guard points.indices.contains(index) else { return }
            points[index] = point.clamped
            item.points = points
        }
    }

    // MARK: Layers

    public static func addingLayer(_ name: String, to file: MapFile) -> (MapFile, String) {
        var copy = file
        let id = shortID("l", used: file.usedIDs)
        copy.layers.append(MapLayer(id: id, name: name))
        return (copy, id)
    }

    public static func renamingLayer(_ id: String, to name: String, in file: MapFile) -> MapFile {
        guard let index = file.layers.firstIndex(where: { $0.id == id }) else { return file }
        var copy = file
        copy.layers[index].name = name
        return copy
    }

    /// Removes a layer; its items stay, always shown.
    public static func removingLayer(_ id: String, from file: MapFile) -> MapFile {
        var copy = file
        copy.layers.removeAll { $0.id == id }
        for item in copy.items where item.layer == id {
            copy = updating(item.id, in: copy) { $0.layer = nil }
        }
        return copy
    }
}

/// Hit tests in normalised map space.
public enum MapGeometry {
    /// Even-odd point-in-polygon.
    public static func contains(_ polygon: [MapPoint], _ point: MapPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Shortest distance from a point to a polyline, scaled by `aspect` (width ÷ height) so it's even in both directions.
    public static func distance(from point: MapPoint, to line: [MapPoint], aspect: Double = 1) -> Double {
        func scaled(_ p: MapPoint) -> MapPoint { MapPoint(x: p.x * aspect, y: p.y) }
        let p = scaled(point)
        guard let first = line.first else { return .infinity }
        if line.count == 1 { return hypot(p.x - scaled(first).x, p.y - scaled(first).y) }
        var best = Double.infinity
        for (a, b) in zip(line, line.dropFirst()).map({ (scaled($0), scaled($1)) }) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length, 0), 1)
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
        }
        return best
    }

    /// The middle of the points' bounding box (where a label goes).
    public static func centre(_ points: [MapPoint]) -> MapPoint {
        guard !points.isEmpty else { return MapPoint(x: 0.5, y: 0.5) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return MapPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
    }
}
