import Foundation

/// A note's headings as a tree, for the Universe sidebar's index.
public enum HeadingTree {
    public struct Node: Sendable, Equatable, Identifiable {
        public let heading: MarkdownOutline.Heading
        public var children: [Node]
        /// The path of titles (`Ghost/1987`), with ` #2` for a repeat. Stable
        /// when lines move, so collapse state survives edits elsewhere.
        public let key: String
        public var id: String { key }
    }

    /// One visible row of a tree: a node at a depth.
    public struct Row: Sendable, Equatable, Identifiable {
        public let node: Node
        public let depth: Int
        public var id: String { node.key }
    }

    /// Nests each heading under the nearest heading above it with a lower level.
    /// - Parameter droppingTitle: A level-1 heading with this title (the note's name) is left out.
    public static func build(_ headings: [MarkdownOutline.Heading], droppingTitle: String? = nil) -> [Node] {
        let dropped = droppingTitle.map(LinkGraph.key)
        let list = headings.filter { !($0.level == 1 && dropped != nil && LinkGraph.key($0.title) == dropped) }
        var used: [String: Int] = [:]
        var index = 0

        func key(_ path: String) -> String {
            used[path, default: 0] += 1
            let count = used[path]!
            return count == 1 ? path : "\(path) #\(count)"
        }

        // Builds the children of a parent at `level`, consuming headings deeper than it.
        func children(above level: Int, path: String) -> [Node] {
            var nodes: [Node] = []
            while index < list.count, list[index].level > level {
                let heading = list[index]
                index += 1
                let title = heading.title.replacingOccurrences(of: "/", with: "∕")
                let nodePath = path.isEmpty ? title : path + "/" + title
                let nodeKey = key(nodePath)
                let kids = children(above: heading.level, path: nodeKey)
                nodes.append(Node(heading: heading, children: kids, key: nodeKey))
            }
            return nodes
        }
        var roots: [Node] = []
        while index < list.count {
            roots += children(above: 0, path: "")
        }
        return roots
    }

    /// The rows to show: every node in order, skipping the children of closed ones.
    public static func rows(_ nodes: [Node], isOpen: (String) -> Bool, depth: Int = 0) -> [Row] {
        nodes.flatMap { node -> [Row] in
            [Row(node: node, depth: depth)] + (isOpen(node.key) ? rows(node.children, isOpen: isOpen, depth: depth + 1) : [])
        }
    }

    /// Every key in a tree (for Expand All).
    public static func keys(_ nodes: [Node]) -> [String] {
        nodes.flatMap { [$0.key] + keys($0.children) }
    }
}
