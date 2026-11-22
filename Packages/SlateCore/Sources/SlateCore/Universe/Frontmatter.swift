import Foundation
import Yams

/// A YAML value as Slate's forms see it. Mappings keep their key order.
public indirect enum YAMLValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([YAMLValue])
    case map([YAMLField])

    /// The value as one line of text, for display and search.
    public var text: String {
        switch self {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .list(let items): items.map(\.text).joined(separator: ", ")
        case .map(let fields): fields.map { "\($0.key): \($0.value.text)" }.joined(separator: ", ")
        }
    }

    /// Items for a list field. A single scalar counts as a one-item list.
    public var items: [String] {
        switch self {
        case .null: []
        case .list(let items): items.map(\.text).filter { !$0.isEmpty }
        default: text.isEmpty ? [] : [text]
        }
    }

    public var isEmpty: Bool { text.isEmpty }

    public subscript(key: String) -> YAMLValue? {
        guard case .map(let fields) = self else { return nil }
        return fields.first { $0.key == key }?.value
    }
}

public struct YAMLField: Sendable, Equatable, Codable {
    public let key: String
    public let value: YAMLValue

    public init(_ key: String, _ value: YAMLValue) {
        self.key = key
        self.value = value
    }
}

public struct FrontmatterError: Error, Equatable, LocalizedError {
    public let message: String
    public var errorDescription: String? { "The frontmatter isn't valid YAML: \(message)" }
}

/// YAML frontmatter at the top of a note: `---`, YAML, `---`, then the body.
///
/// Reading uses Yams. Writing never re-serialises the whole block: changing
/// one field replaces only that key's lines, so comments, key order, quoting
/// and everything else a person typed stay exactly as they were.
public enum Frontmatter {
    /// Where the block sits in a note.
    public struct Split: Sendable, Equatable {
        /// The YAML between the fences, or nil when the note has no block.
        public let yaml: String?
        /// Everything after the closing fence's line.
        public let body: String
        /// UTF-16 offset of `body` in the note, for mapping ranges back.
        public let bodyOffset: Int
    }

    public static func split(_ text: String) -> Split {
        let lines = lineRanges(text)
        guard let first = lines.first, isFence(text[first], opening: true) else {
            return Split(yaml: nil, body: text, bodyOffset: 0)
        }
        for line in lines.dropFirst() where isFence(text[line], opening: false) {
            let yaml = String(text[first.upperBound..<line.lowerBound]).droppingLeadingNewline()
            let bodyStart = text[line.upperBound...].first?.isNewline == true ? text.index(after: line.upperBound) : line.upperBound
            return Split(yaml: yaml, body: String(text[bodyStart...]), bodyOffset: text.utf16.distance(from: text.startIndex, to: bodyStart))
        }
        return Split(yaml: nil, body: text, bodyOffset: 0)
    }

    /// The fields in order. Throws if the YAML can't be read; a block that
    /// isn't a mapping (a bare scalar or list) reads as no fields.
    public static func fields(in text: String) throws -> [YAMLField] {
        guard let yaml = split(text).yaml else { return [] }
        return try parse(yaml)
    }

    public static func parse(_ yaml: String) throws -> [YAMLField] {
        guard !yaml.allSatisfy(\.isWhitespace) else { return [] }
        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch {
            throw FrontmatterError(message: Self.describe(error))
        }
        guard let node, case .map(let fields) = value(of: node) else { return [] }
        return fields
    }

    // MARK: - Writing

    /// Sets one top-level key, replacing only its lines. A new key goes at the
    /// end of the block; a note without a block gets one. Nil removes the key.
    public static func setting(_ key: String, to value: YAMLValue?, in text: String) -> String {
        guard let value else { return removing(key, in: text) }
        let newLines = emit(key: key, value: value)
        guard split(text).yaml != nil else {
            return "---\n" + newLines + "\n---\n" + text
        }
        var lines = text.components(separatedBy: "\n")
        let closing = closingFenceIndex(lines)!
        if let extent = keyExtent(key, in: lines, closing: closing) {
            lines.replaceSubrange(extent, with: [newLines])
        } else {
            lines.insert(newLines, at: closing)
        }
        return lines.joined(separator: "\n")
    }

    /// Removes one top-level key and its lines; nothing else changes.
    public static func removing(_ key: String, in text: String) -> String {
        guard split(text).yaml != nil else { return text }
        var lines = text.components(separatedBy: "\n")
        guard let closing = closingFenceIndex(lines), let extent = keyExtent(key, in: lines, closing: closing) else { return text }
        lines.removeSubrange(extent)
        return lines.joined(separator: "\n")
    }

    /// Replaces the body, keeping the frontmatter block byte for byte.
    public static func replacingBody(of text: String, with body: String) -> String {
        let split = split(text)
        let head = String(text.utf16.prefix(split.bodyOffset)) ?? ""
        return head + body
    }

    /// `key: value` in Slate's style: scalars and flow lists on one line,
    /// quoted only when YAML would misread them.
    public static func emit(key: String, value: YAMLValue) -> String {
        let rendered = emit(value)
        return rendered.isEmpty ? "\(key):" : "\(key): \(rendered)"
    }

    public static func emit(_ value: YAMLValue) -> String {
        switch value {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): quotedIfNeeded(value)
        case .list(let items): "[" + items.map { emit($0) }.joined(separator: ", ") + "]"
        case .map(let fields): "{" + fields.map { "\($0.key): \(emit($0.value))" }.joined(separator: ", ") + "}"
        }
    }

    static func quotedIfNeeded(_ string: String) -> String {
        guard needsQuotes(string) else { return string }
        var escaped = ""
        for char in string {
            switch char {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(char)
            }
        }
        return "\"" + escaped + "\""
    }

    private static func needsQuotes(_ string: String) -> Bool {
        guard let first = string.first, let last = string.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if "[]{},&*#?|-<>=!%@`\"'".contains(first) { return true }
        if string.contains(": ") || string.contains(" #") || string.hasSuffix(":") { return true }
        if string.contains(where: { $0.isNewline || $0 == "\t" }) { return true }
        if string.contains(",") || string.contains("]") || string.contains("}") { return true }
        let lower = string.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"].contains(lower) { return true }
        if Double(string) != nil || Int(string) != nil { return true }
        if string.hasPrefix("0x") || string.hasPrefix("0o") { return true }
        // Dates are read back as strings by Slate, but keep them unquoted:
        // `2031-03-14` is what a person would type.
        return false
    }

    // MARK: - Helpers

    static func value(of node: Node) -> YAMLValue {
        switch node {
        case .scalar(let scalar):
            guard scalar.style == .plain || scalar.style == .any else { return .string(scalar.string) }
            if node.null != nil { return .null }
            if let value = node.bool { return .bool(value) }
            if let value = node.int { return .int(value) }
            if let value = node.float, value.isFinite { return .double(value) }
            return .string(scalar.string)
        case .sequence(let sequence):
            return .list(sequence.map(value(of:)))
        case .mapping(let mapping):
            return .map(mapping.map { YAMLField($0.key.string ?? "", value(of: $0.value)) })
        case .alias:
            return .null
        }
    }

    private static func describe(_ error: any Error) -> String {
        // YamlError's description quotes the line and marks the column.
        String(describing: error).split(whereSeparator: \.isNewline).first.map(String.init) ?? "unreadable"
    }

    private static func isFence(_ line: Substring, opening: Bool) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "---" || (!opening && trimmed == "...")
    }

    private static func lineRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            ranges.append(start..<end)
            start = end < text.endIndex ? text.index(after: end) : end
        }
        return ranges
    }

    private static func closingFenceIndex(_ lines: [String]) -> Int? {
        guard let first = lines.first, isFence(Substring(first.trimmingCharacters(in: .newlines)), opening: true) else { return nil }
        return lines.indices.dropFirst().first { isFence(Substring(lines[$0].trimmingCharacters(in: .newlines)), opening: false) }
    }

    /// The lines a top-level key spans: its own line plus indented or `- `
    /// continuation lines, not counting trailing blank lines or comments.
    private static func keyExtent(_ key: String, in lines: [String], closing: Int) -> Range<Int>? {
        guard let start = (1..<closing).first(where: { topLevelKey(of: lines[$0]) == key }) else { return nil }
        var end = start + 1
        var lastContent = start
        while end < closing {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                end += 1
                continue
            }
            let indented = line.first == " " || line.first == "\t"
            guard indented || line.hasPrefix("- ") || line == "-" else { break }
            lastContent = end
            end += 1
        }
        return start..<(lastContent + 1)
    }

    private static func topLevelKey(of line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#", first != "-" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let after = line.index(after: colon)
        guard after == line.endIndex || line[after] == " " || line[after] == "\t" || line[after] == "\r" else { return nil }
        var key = line[..<colon].trimmingCharacters(in: .whitespaces)
        if key.count >= 2, let q = key.first, q == "\"" || q == "'", key.last == q {
            key = String(key.dropFirst().dropLast())
        }
        return key
    }
}

private extension String {
    func droppingLeadingNewline() -> String {
        first?.isNewline == true ? String(dropFirst()) : self
    }
}
