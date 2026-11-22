import Foundation

/// A rectangle in canvas coordinates (y grows downwards, as in JSON Canvas).
public struct CanvasRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(_ other: CanvasRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }

    public func intersects(_ other: CanvasRect) -> Bool {
        other.x < maxX && other.maxX > x && other.y < maxY && other.maxY > y
    }

    public func union(_ other: CanvasRect) -> CanvasRect {
        let minX = min(x, other.x), minY = min(y, other.y)
        return CanvasRect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
    }
}

/// One node of a JSON Canvas file. Every key Slate doesn't know is kept,
/// in order, so the file round-trips.
public struct CanvasNode: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case text, file, link, group
    }

    public var object: JSONObject

    public init(object: JSONObject) {
        self.object = object
    }

    /// A new node: id, type, then geometry, then the type's own keys (the order Obsidian writes).
    public init(id: String, kind: Kind, rect: CanvasRect, extra: [(String, OrderedJSON)] = []) {
        var object = JSONObject([("id", .string(id)), ("type", .string(kind.rawValue))])
        for (key, value) in extra { object[key] = value }
        object["x"] = .number(rect.x.rounded())
        object["y"] = .number(rect.y.rounded())
        object["width"] = .number(rect.width.rounded())
        object["height"] = .number(rect.height.rounded())
        self.object = object
    }

    public var id: String { object["id"]?.string ?? "" }
    public var typeName: String { object["type"]?.string ?? "" }
    public var kind: Kind? { Kind(rawValue: typeName) }

    public var rect: CanvasRect {
        get {
            CanvasRect(x: object["x"]?.double ?? 0, y: object["y"]?.double ?? 0,
                       width: object["width"]?.double ?? 250, height: object["height"]?.double ?? 60)
        }
        set {
            if newValue.x != rect.x { object["x"] = .number(newValue.x.rounded()) }
            if newValue.y != rect.y { object["y"] = .number(newValue.y.rounded()) }
            if newValue.width != rect.width { object["width"] = .number(max(newValue.width, 20).rounded()) }
            if newValue.height != rect.height { object["height"] = .number(max(newValue.height, 20).rounded()) }
        }
    }

    /// `"1"`–`"6"` (the app's palette) or a hex colour.
    public var color: String? {
        get { object["color"]?.string }
        set { object["color"] = newValue.map(OrderedJSON.string) }
    }

    public var text: String {
        get { object["text"]?.string ?? "" }
        set { object["text"] = .string(newValue) }
    }

    public var file: String? { object["file"]?.string }
    /// `#heading` or `#^block` (Slate uses `#s014` for a scene).
    public var subpath: String? { object["subpath"]?.string }
    public var url: String? { object["url"]?.string }

    public var label: String? {
        get { object["label"]?.string }
        set { object["label"] = newValue.map(OrderedJSON.string) }
    }

    /// What Slate shows for the node.
    public var card: CanvasCard {
        switch kind {
        case .text: return .text
        case .link: return .link(url ?? "")
        case .group: return .group
        case .file:
            let path = file ?? ""
            let ext = (path as NSString).pathExtension.lowercased()
            if CanvasCard.imageExtensions.contains(ext) { return .image(path) }
            if let subpath, subpath.hasPrefix("#"), path.hasPrefix(ProjectLayout.script + "/") {
                return .scene(file: path, sceneID: String(subpath.dropFirst()))
            }
            if ["md", "markdown"].contains(ext), path.hasPrefix(ProjectLayout.universe + "/") { return .note(path) }
            return .file(path)
        case nil:
            return .unknown(typeName)
        }
    }
}

/// The kinds of card Slate draws.
public enum CanvasCard: Sendable, Equatable {
    case text
    case note(String)
    case scene(file: String, sceneID: String)
    case image(String)
    case link(String)
    case group
    /// Any other file (a PDF, an act file without a scene).
    case file(String)
    /// A node type from a newer JSON Canvas version.
    case unknown(String)

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "svg", "avif"]
}

public struct CanvasEdge: Sendable, Equatable, Identifiable {
    public enum Side: String, Sendable, CaseIterable {
        case top, right, bottom, left
    }

    public var object: JSONObject

    public init(object: JSONObject) {
        self.object = object
    }

    public init(id: String, from: String, fromSide: Side?, to: String, toSide: Side?) {
        var object = JSONObject([("id", .string(id)), ("fromNode", .string(from))])
        if let fromSide { object["fromSide"] = .string(fromSide.rawValue) }
        object["toNode"] = .string(to)
        if let toSide { object["toSide"] = .string(toSide.rawValue) }
        self.object = object
    }

    public var id: String { object["id"]?.string ?? "" }
    public var fromNode: String { object["fromNode"]?.string ?? "" }
    public var toNode: String { object["toNode"]?.string ?? "" }
    public var fromSide: Side? { object["fromSide"]?.string.flatMap(Side.init(rawValue:)) }
    public var toSide: Side? { object["toSide"]?.string.flatMap(Side.init(rawValue:)) }

    /// JSON Canvas defaults: no arrow at the start, an arrow at the end.
    public var fromArrow: Bool {
        get { object["fromEnd"]?.string == "arrow" }
        set { object["fromEnd"] = newValue ? .string("arrow") : nil }
    }

    public var toArrow: Bool {
        get { object["toEnd"]?.string != "none" }
        set { object["toEnd"] = newValue ? nil : .string("none") }
    }

    public var color: String? {
        get { object["color"]?.string }
        set { object["color"] = newValue.map(OrderedJSON.string) }
    }

    public var label: String? {
        get { object["label"]?.string }
        set { object["label"] = newValue.flatMap { $0.isEmpty ? nil : .string($0) } }
    }
}

/// A `.canvas` file (JSON Canvas 1.0, as Obsidian reads and writes it).
public struct CanvasFile: Sendable, Equatable {
    public var nodes: [CanvasNode]
    public var edges: [CanvasEdge]
    /// Top-level keys other than nodes and edges, kept as they were.
    public var extra: JSONObject

    public init(nodes: [CanvasNode] = [], edges: [CanvasEdge] = [], extra: JSONObject = JSONObject()) {
        self.nodes = nodes
        self.edges = edges
        self.extra = extra
    }

    public static let empty = "{\n\t\"nodes\":[],\n\t\"edges\":[]\n}"

    /// Reads a canvas. An empty file is an empty canvas.
    public init(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.init()
            return
        }
        guard case .object(var root) = try OrderedJSON.parse(text) else {
            throw OrderedJSON.ParseError(message: "a canvas must be a JSON object", offset: 0)
        }
        let nodes = (root["nodes"]?.array ?? []).compactMap { $0.object.map(CanvasNode.init(object:)) }
        let edges = (root["edges"]?.array ?? []).compactMap { $0.object.map(CanvasEdge.init(object:)) }
        root["nodes"] = nil
        root["edges"] = nil
        self.init(nodes: nodes, edges: edges, extra: root)
    }

    /// The file as JSON Canvas apps write it: tab-indented, one node or edge per line.
    public var text: String {
        func list(_ objects: [JSONObject]) -> String {
            guard !objects.isEmpty else { return "[]" }
            return "[\n" + objects.map { "\t\t" + OrderedJSON.object($0).compact }.joined(separator: ",\n") + "\n\t]"
        }
        var parts = ["\t\"nodes\":" + list(nodes.map(\.object)), "\t\"edges\":" + list(edges.map(\.object))]
        for pair in extra.pairs {
            parts.append("\t" + OrderedJSON.quote(pair.key) + ":" + pair.value.compact)
        }
        return "{\n" + parts.joined(separator: ",\n") + "\n}"
    }

    public func node(_ id: String) -> CanvasNode? {
        nodes.first { $0.id == id }
    }

    public func index(of id: String) -> Int? {
        nodes.firstIndex { $0.id == id }
    }

    /// Everything's bounding box, or nil for an empty canvas.
    public var bounds: CanvasRect? {
        nodes.map(\.rect).reduce(nil) { $0?.union($1) ?? $1 }
    }
}
