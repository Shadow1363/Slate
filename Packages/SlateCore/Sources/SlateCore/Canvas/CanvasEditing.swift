import Foundation

/// Edits on a canvas, as pure functions of `CanvasFile`.
public enum CanvasEditing {
    public static let grid: Double = 20

    public enum Alignment: String, Sendable, CaseIterable {
        case left, centerX, right, top, centerY, bottom
    }

    public enum Axis: Sendable {
        case horizontal, vertical
    }

    /// A 16-hex-digit ID like Obsidian's, not already used.
    public static func newID(in canvas: CanvasFile) -> String {
        let used = Set(canvas.nodes.map(\.id) + canvas.edges.map(\.id))
        while true {
            let id = (0..<16).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
            if !used.contains(id) { return id }
        }
    }

    public static func snap(_ value: Double) -> Double {
        (value / grid).rounded() * grid
    }

    // MARK: - Adding

    /// Adds a node. Groups go first so they draw behind cards.
    public static func adding(_ node: CanvasNode, to canvas: CanvasFile) -> CanvasFile {
        var copy = canvas
        if node.kind == .group {
            copy.nodes.insert(node, at: 0)
        } else {
            copy.nodes.append(node)
        }
        return copy
    }

    public static func textCard(_ text: String, at rect: CanvasRect, in canvas: CanvasFile) -> CanvasNode {
        CanvasNode(id: newID(in: canvas), kind: .text, rect: rect, extra: [("text", .string(text))])
    }

    public static func fileCard(_ path: String, subpath: String? = nil, at rect: CanvasRect, in canvas: CanvasFile) -> CanvasNode {
        var extra: [(String, OrderedJSON)] = [("file", .string(path))]
        if let subpath { extra.append(("subpath", .string(subpath))) }
        return CanvasNode(id: newID(in: canvas), kind: .file, rect: rect, extra: extra)
    }

    public static func linkCard(_ url: String, at rect: CanvasRect, in canvas: CanvasFile) -> CanvasNode {
        CanvasNode(id: newID(in: canvas), kind: .link, rect: rect, extra: [("url", .string(url))])
    }

    public static func group(_ label: String?, at rect: CanvasRect, in canvas: CanvasFile) -> CanvasNode {
        var node = CanvasNode(id: newID(in: canvas), kind: .group, rect: rect)
        if let label, !label.isEmpty { node.label = label }
        return node
    }

    /// A frame around `ids` with some room for its label.
    public static func grouping(_ ids: Set<String>, label: String?, in canvas: CanvasFile) -> (CanvasFile, String)? {
        let rects = canvas.nodes.filter { ids.contains($0.id) }.map(\.rect)
        guard let first = rects.first else { return nil }
        let box = rects.dropFirst().reduce(first) { $0.union($1) }
        let padded = CanvasRect(x: box.x - 40, y: box.y - 60, width: box.width + 80, height: box.height + 100)
        let node = group(label, at: padded, in: canvas)
        // Insert just below the lowest member so it stays behind them.
        var copy = canvas
        let firstMember = copy.nodes.firstIndex { ids.contains($0.id) } ?? 0
        copy.nodes.insert(node, at: firstMember)
        return (copy, node.id)
    }

    // MARK: - Removing

    /// Removes nodes and every edge touching them, and edges by ID.
    public static func removing(_ ids: Set<String>, from canvas: CanvasFile) -> CanvasFile {
        var copy = canvas
        copy.nodes.removeAll { ids.contains($0.id) }
        copy.edges.removeAll { ids.contains($0.id) || ids.contains($0.fromNode) || ids.contains($0.toNode) }
        return copy
    }

    // MARK: - Moving and sizing

    /// Nodes that sit entirely inside a group's frame (how JSON Canvas apps decide membership).
    public static func members(of groupID: String, in canvas: CanvasFile) -> [String] {
        guard let group = canvas.node(groupID), group.kind == .group else { return [] }
        let frame = group.rect
        return canvas.nodes.filter { $0.id != groupID && frame.contains($0.rect) }.map(\.id)
    }

    /// The IDs that move when `ids` are dragged: the nodes, plus everything inside any group among them.
    public static func carried(_ ids: Set<String>, in canvas: CanvasFile) -> Set<String> {
        var result = ids
        var queue = Array(ids)
        while let id = queue.popLast() {
            for member in members(of: id, in: canvas) where !result.contains(member) {
                result.insert(member)
                queue.append(member)
            }
        }
        return result
    }

    public static func moving(_ ids: Set<String>, by dx: Double, _ dy: Double, in canvas: CanvasFile, snapToGrid: Bool = false) -> CanvasFile {
        guard dx != 0 || dy != 0 else { return canvas }
        var copy = canvas
        var dx = dx, dy = dy
        if snapToGrid, let lead = canvas.nodes.first(where: { ids.contains($0.id) }) {
            dx = snap(lead.rect.x + dx) - lead.rect.x
            dy = snap(lead.rect.y + dy) - lead.rect.y
        }
        for index in copy.nodes.indices where ids.contains(copy.nodes[index].id) {
            var rect = copy.nodes[index].rect
            rect.x += dx
            rect.y += dy
            copy.nodes[index].rect = rect
        }
        return copy
    }

    public static func resizing(_ id: String, to rect: CanvasRect, in canvas: CanvasFile, snapToGrid: Bool = false) -> CanvasFile {
        guard let index = canvas.index(of: id) else { return canvas }
        var copy = canvas
        var rect = rect
        if snapToGrid {
            rect = CanvasRect(x: snap(rect.x), y: snap(rect.y), width: max(snap(rect.width), grid), height: max(snap(rect.height), grid))
        }
        rect.width = max(rect.width, 40)
        rect.height = max(rect.height, 30)
        copy.nodes[index].rect = rect
        return copy
    }

    /// Moves nodes to the end of the list (drawn on top). Groups stay behind cards.
    public static func bringingToFront(_ ids: Set<String>, in canvas: CanvasFile) -> CanvasFile {
        var copy = canvas
        let moving = copy.nodes.filter { ids.contains($0.id) }
        copy.nodes.removeAll { ids.contains($0.id) }
        let groups = moving.filter { $0.kind == .group }
        let cards = moving.filter { $0.kind != .group }
        let lastGroup = copy.nodes.lastIndex { $0.kind == .group }.map { $0 + 1 } ?? 0
        copy.nodes.insert(contentsOf: groups, at: lastGroup)
        copy.nodes.append(contentsOf: cards)
        return copy
    }

    // MARK: - Align and distribute

    public static func aligning(_ ids: Set<String>, _ alignment: Alignment, in canvas: CanvasFile) -> CanvasFile {
        let rects = canvas.nodes.filter { ids.contains($0.id) }.map(\.rect)
        guard rects.count > 1 else { return canvas }
        let target: Double = switch alignment {
        case .left: rects.map(\.x).min()!
        case .right: rects.map(\.maxX).max()!
        case .top: rects.map(\.y).min()!
        case .bottom: rects.map(\.maxY).max()!
        case .centerX: rects.map(\.midX).reduce(0, +) / Double(rects.count)
        case .centerY: rects.map(\.midY).reduce(0, +) / Double(rects.count)
        }
        var copy = canvas
        for index in copy.nodes.indices where ids.contains(copy.nodes[index].id) {
            var rect = copy.nodes[index].rect
            switch alignment {
            case .left: rect.x = target
            case .right: rect.x = target - rect.width
            case .centerX: rect.x = (target - rect.width / 2).rounded()
            case .top: rect.y = target
            case .bottom: rect.y = target - rect.height
            case .centerY: rect.y = (target - rect.height / 2).rounded()
            }
            copy.nodes[index].rect = rect
        }
        return copy
    }

    /// Equal gaps between the nodes, keeping the first and last where they are.
    public static func distributing(_ ids: Set<String>, _ axis: Axis, in canvas: CanvasFile) -> CanvasFile {
        let chosen = canvas.nodes.filter { ids.contains($0.id) }
        guard chosen.count > 2 else { return canvas }
        let sorted = chosen.sorted { axis == .horizontal ? $0.rect.x < $1.rect.x : $0.rect.y < $1.rect.y }
        let first = sorted.first!.rect, last = sorted.last!.rect
        let span = axis == .horizontal ? last.maxX - first.x : last.maxY - first.y
        let sizes = sorted.map { axis == .horizontal ? $0.rect.width : $0.rect.height }.reduce(0, +)
        let gap = (span - sizes) / Double(sorted.count - 1)
        var position = axis == .horizontal ? first.x : first.y
        var copy = canvas
        for node in sorted {
            guard let index = copy.index(of: node.id) else { continue }
            var rect = copy.nodes[index].rect
            if axis == .horizontal { rect.x = position.rounded() } else { rect.y = position.rounded() }
            position += (axis == .horizontal ? rect.width : rect.height) + gap
            copy.nodes[index].rect = rect
        }
        return copy
    }

    // MARK: - Connections

    /// Which sides to join, from where the two cards sit.
    public static func sides(from a: CanvasRect, to b: CanvasRect) -> (CanvasEdge.Side, CanvasEdge.Side) {
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        if abs(dx) >= abs(dy) {
            return dx >= 0 ? (.right, .left) : (.left, .right)
        }
        return dy >= 0 ? (.bottom, .top) : (.top, .bottom)
    }

    /// Connects two nodes, choosing sides unless given. Returns the edge's ID.
    public static func connecting(_ from: String, to: String, fromSide: CanvasEdge.Side? = nil, toSide: CanvasEdge.Side? = nil,
                                  in canvas: CanvasFile) -> (CanvasFile, String)? {
        guard from != to, let a = canvas.node(from), let b = canvas.node(to) else { return nil }
        let auto = sides(from: a.rect, to: b.rect)
        let edge = CanvasEdge(id: newID(in: canvas), from: from, fromSide: fromSide ?? auto.0, to: to, toSide: toSide ?? auto.1)
        var copy = canvas
        copy.edges.append(edge)
        return (copy, edge.id)
    }

    /// The point on a side of a rectangle where a connection meets it.
    public static func anchor(_ rect: CanvasRect, _ side: CanvasEdge.Side) -> (x: Double, y: Double) {
        switch side {
        case .top: (rect.midX, rect.y)
        case .bottom: (rect.midX, rect.maxY)
        case .left: (rect.x, rect.midY)
        case .right: (rect.maxX, rect.midY)
        }
    }

    // MARK: - Editing nodes

    public static func updating(_ id: String, in canvas: CanvasFile, _ change: (inout CanvasNode) -> Void) -> CanvasFile {
        guard let index = canvas.index(of: id) else { return canvas }
        var copy = canvas
        change(&copy.nodes[index])
        return copy
    }

    public static func updatingEdge(_ id: String, in canvas: CanvasFile, _ change: (inout CanvasEdge) -> Void) -> CanvasFile {
        guard let index = canvas.edges.firstIndex(where: { $0.id == id }) else { return canvas }
        var copy = canvas
        change(&copy.edges[index])
        return copy
    }

    /// Nodes whose rectangle meets `rect` (marquee selection).
    public static func nodes(in rect: CanvasRect, of canvas: CanvasFile) -> [String] {
        canvas.nodes.filter { rect.intersects($0.rect) && ($0.kind != .group || rect.contains($0.rect)) }.map(\.id)
    }
}
