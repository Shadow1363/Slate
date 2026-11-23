import Foundation

/// The script lines a frame covers, by position inside its scene:
/// `action-1` (the first action line) or `action-1..dialogue-2`.
/// Positions count lines of one kind from the heading, starting at 1, so
/// rewording a line keeps the link; adding a line above it shifts it.
public struct ScriptRange: Sendable, Equatable, CustomStringConvertible {
    public struct Element: Sendable, Equatable, Hashable, CustomStringConvertible {
        public let kind: ScriptElementKind
        public let number: Int

        public init(kind: ScriptElementKind, number: Int) {
            self.kind = kind
            self.number = number
        }

        public var description: String { "\(ScriptRange.name(of: kind))-\(number)" }

        /// `action-1`.
        public init?(_ text: String) {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
            guard parts.count >= 2, let number = Int(parts.last!), number > 0,
                  let kind = ScriptRange.kind(named: parts.dropLast().joined(separator: "-")) else { return nil }
            self.init(kind: kind, number: number)
        }
    }

    public let start: Element
    public let end: Element

    public init(start: Element, end: Element? = nil) {
        self.start = start
        self.end = end ?? start
    }

    public init?(_ text: String) {
        let parts = text.components(separatedBy: "..")
        guard (1...2).contains(parts.count), let start = Element(parts[0]) else { return nil }
        if parts.count == 2 {
            guard let end = Element(parts[1]) else { return nil }
            self.init(start: start, end: end)
        } else {
            self.init(start: start)
        }
    }

    public var description: String { start == end ? start.description : "\(start)..\(end)" }

    // MARK: Names

    /// The word for a kind in the file: `heading`, `action`, `dialogue`…
    public static func name(of kind: ScriptElementKind) -> String {
        switch kind {
        case .sceneHeading: "heading"
        case .pageBreak: "pagebreak"
        default: kind.rawValue.lowercased()
        }
    }

    static func kind(named name: String) -> ScriptElementKind? {
        let lowered = name.lowercased()
        return ScriptElementKind.allCases.first { Self.name(of: $0) == lowered }
    }

    // MARK: Resolving

    /// Each non-blank line of the scene with its element reference.
    public static func elements(in scene: ScriptScene, of parsed: ParsedScript) -> [(line: Int, element: Element)] {
        var counts: [ScriptElementKind: Int] = [:]
        var result: [(line: Int, element: Element)] = []
        for index in scene.lines where parsed.lines.indices.contains(index) {
            let kind = parsed.lines[index].kind
            guard kind != .blank else { continue }
            counts[kind, default: 0] += 1
            result.append((index, Element(kind: kind, number: counts[kind]!)))
        }
        return result
    }

    /// The line indices covered, in order; nil if either end isn't in the scene any more.
    public func lines(in scene: ScriptScene, of parsed: ParsedScript) -> [Int]? {
        let elements = Self.elements(in: scene, of: parsed)
        guard let first = elements.firstIndex(where: { $0.element == start }),
              let last = elements.firstIndex(where: { $0.element == end }) else { return nil }
        let (a, b) = first <= last ? (first, last) : (last, first)
        return elements[a...b].map(\.line)
    }

    /// The element at a line, for finding the frames that cover it.
    public static func element(atLine line: Int, in scene: ScriptScene, of parsed: ParsedScript) -> Element? {
        elements(in: scene, of: parsed).first { $0.line == line }?.element
    }

    /// Whether a range covers a line of the scene.
    public func covers(line: Int, in scene: ScriptScene, of parsed: ParsedScript) -> Bool {
        lines(in: scene, of: parsed)?.contains(line) ?? false
    }
}
