import Foundation

/// One note in `script/margin/notes.md`: a list item under a scene's heading.
///
/// ```markdown
/// ## @s014
///
/// - "I haven't opened it yet" — she has, in the 1998 loop. See [[The Brass Key]].
/// ```
public struct MarginNote: Sendable, Equatable, Identifiable {
    /// nil for notes above the first `## @scene` heading.
    public let sceneID: String?
    /// 0-based lines the item spans (the `- ` line plus continuation lines).
    public let lines: Range<Int>
    /// The item's text as written, without the `- ` and with continuation
    /// lines joined by newlines.
    public let markdown: String
    /// The words it points at, from a leading `"quoted words" —`.
    public let quote: String?
    /// The note without its quote.
    public let text: String

    public var id: String { "\(lines.lowerBound):\(markdown)" }
    public var links: [WikiLink] { WikiLink.find(in: markdown) }
}

/// Reads and edits `script/margin/notes.md`. Edits touch only the item's
/// own lines (or add a scene section at the end), so the rest of the file
/// stays as written.
public enum MarginNotes {
    public static let path = "script/margin/notes.md"

    public static func parse(_ text: String) -> [MarginNote] {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var notes: [MarginNote] = []
        var scene: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let id = sceneID(inHeading: line) {
                scene = id
                index += 1
                continue
            }
            if line.hasPrefix("#") {
                // Any other heading ends the scene's section.
                scene = nil
                index += 1
                continue
            }
            guard let match = line.firstMatch(of: /^[-*+]\s+(.*)$/) else {
                index += 1
                continue
            }
            var body = [String(match.1)]
            var end = index + 1
            while end < lines.count, let first = lines[end].first, first == " " || first == "\t" {
                body.append(lines[end].trimmingCharacters(in: .whitespaces))
                end += 1
            }
            let markdown = body.joined(separator: "\n")
            let (quote, rest) = MarginQuote.split(markdown)
            notes.append(MarginNote(sceneID: scene, lines: index..<end, markdown: markdown, quote: quote, text: rest))
            index = end
        }
        return notes
    }

    /// `## @s014` (anything after the ID is ignored) → `s014`.
    static func sceneID(inHeading line: String) -> String? {
        line.firstMatch(of: /^##\s+@([A-Za-z0-9][A-Za-z0-9_-]*)/).map { String($0.1) }
    }

    /// The list item for a note, continuation lines indented.
    static func item(_ markdown: String, quote: String?) -> [String] {
        var text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote, !quote.isEmpty { text = "\"\(quote)\" — " + text }
        let parts = text.components(separatedBy: "\n")
        return ["- " + (parts.first ?? "")] + parts.dropFirst().map { "  " + $0 }
    }

    /// Adds a note at the end of its scene's section, creating the section
    /// (at the end of the file) if there isn't one.
    public static func adding(_ markdown: String, quote: String? = nil, sceneID: String?, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let item = item(markdown, quote: quote)
        if let sceneID, let heading = lines.firstIndex(where: { Self.sceneID(inHeading: $0) == sceneID }) {
            var end = heading + 1
            while end < lines.count, !lines[end].hasPrefix("#") { end += 1 }
            // Insert after the section's last non-blank line.
            var insert = end
            while insert > heading + 1, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
            if insert == heading + 1 {
                lines.insert(contentsOf: [""] + item, at: insert)
            } else {
                lines.insert(contentsOf: item, at: insert)
            }
        } else if let sceneID {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines += ["## @\(sceneID)", ""] + item
        } else {
            // Unanchored notes go above the first scene section.
            let first = lines.firstIndex { Self.sceneID(inHeading: $0) != nil } ?? lines.count
            var insert = first
            while insert > 0, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
            var block = item
            let previous = insert > 0 ? lines[insert - 1] : ""
            let followsItem = previous.hasPrefix("- ") || previous.hasPrefix("  ")
            if insert > 0, !followsItem { block = [""] + block }
            if first < lines.count, insert == first { block += [""] }
            lines.insert(contentsOf: block, at: insert)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Replaces a note's lines. Returns nil if they changed since they were read.
    public static func replacing(_ note: MarginNote, with markdown: String, quote: String?, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard verify(note, lines) else { return nil }
        lines.replaceSubrange(note.lines, with: item(markdown, quote: quote))
        return lines.joined(separator: "\n")
    }

    /// Removes a note's lines. Returns nil if they changed since they were read.
    public static func removing(_ note: MarginNote, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard verify(note, lines) else { return nil }
        lines.removeSubrange(note.lines)
        return lines.joined(separator: "\n")
    }

    private static func verify(_ note: MarginNote, _ lines: [String]) -> Bool {
        guard note.lines.upperBound <= lines.count else { return false }
        let current = parse(lines[note.lines].joined(separator: "\n"))
        return current.first?.markdown == note.markdown
    }
}
