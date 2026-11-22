import Foundation

/// One to-do in `script/margin/todos.md`: a Markdown task-list line.
///
/// ```markdown
/// - [ ] Fix Mara's motivation before the reveal @s014 due:2026-12-01
/// - [ ] "I haven't opened it yet" — tighten this line @s014
/// - [x] Rename the courier @s021
/// ```
///
/// `@s014` anchors it to a scene, `due:` gives a date, and a leading quoted
/// phrase followed by a dash anchors it to those words in the scene.
public struct MarginTodo: Sendable, Equatable, Identifiable {
    /// 0-based line in the file.
    public let line: Int
    /// The line as it was read, to check nothing moved before editing it.
    public let source: String
    public var done: Bool
    /// The words of the to-do, without the anchor tokens or quote.
    public var text: String
    public var sceneID: String?
    /// `YYYY-MM-DD`.
    public var due: String?
    /// The words in the script it points at.
    public var quote: String?

    public var id: String { "\(line):\(source)" }

    public init(line: Int = -1, source: String = "", done: Bool = false, text: String, sceneID: String? = nil, due: String? = nil, quote: String? = nil) {
        self.line = line
        self.source = source
        self.done = done
        self.text = text
        self.sceneID = sceneID
        self.due = due
        self.quote = quote
    }

    /// The due date at midnight in `calendar`'s time zone.
    public func dueDate(calendar: Calendar = .current) -> Date? {
        guard let due, let parts = MarginTodo.dateParts(due) else { return nil }
        return calendar.date(from: parts)
    }

    public func isOverdue(today: Date = .now, calendar: Calendar = .current) -> Bool {
        guard !done, let date = dueDate(calendar: calendar) else { return false }
        return date < calendar.startOfDay(for: today)
    }

    public func isDueToday(today: Date = .now, calendar: Calendar = .current) -> Bool {
        guard !done, let date = dueDate(calendar: calendar) else { return false }
        return calendar.isDate(date, inSameDayAs: today)
    }

    /// The task-list line for this to-do.
    public var markdown: String {
        var parts: [String] = []
        if let quote, !quote.isEmpty { parts.append("\"\(quote)\" —") }
        let words = text.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty { parts.append(words) }
        if let sceneID, !sceneID.isEmpty { parts.append("@" + sceneID) }
        if let due, !due.isEmpty { parts.append("due:" + due) }
        return "- [\(done ? "x" : " ")] " + parts.joined(separator: " ")
    }

    static func dateParts(_ text: String) -> DateComponents? {
        let pieces = text.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, (1...12).contains(pieces[1]), (1...31).contains(pieces[2]) else { return nil }
        return DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
    }
}

/// Reads and edits `script/margin/todos.md` one line at a time, so headings,
/// comments and anything else in the file stay as written.
public enum MarginTodos {
    public static let path = "script/margin/todos.md"

    public static func parse(_ text: String) -> [MarginTodo] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            parseLine(line, index: index)
        }
    }

    static func parseLine(_ raw: String, index: Int) -> MarginTodo? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard let match = line.firstMatch(of: /^\s*[-*+]\s+\[([ xX])\]\s?(.*)$/) else { return nil }
        var rest = String(match.2)
        var sceneID: String?
        var due: String?
        // Tokens may sit anywhere; take the last of each.
        for token in rest.matches(of: /(?:^|\s)@([A-Za-z0-9][A-Za-z0-9_-]*)/) { sceneID = String(token.1) }
        for token in rest.matches(of: /(?:^|\s)due:(\d{4}-\d{1,2}-\d{1,2})/) { due = String(token.1) }
        rest = rest.replacing(/(?:^|\s)@[A-Za-z0-9][A-Za-z0-9_-]*/, with: "")
        rest = rest.replacing(/(?:^|\s)due:\d{4}-\d{1,2}-\d{1,2}/, with: "")
        let (quote, words) = MarginQuote.split(rest.trimmingCharacters(in: .whitespaces))
        return MarginTodo(line: index, source: line, done: match.1 != " ", text: words, sceneID: sceneID, due: due, quote: quote)
    }

    /// Replaces a to-do's line. Returns nil if that line changed since it was read.
    public static func replacing(_ todo: MarginTodo, with updated: MarginTodo, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(todo.line) else { return nil }
        let current = lines[todo.line].hasSuffix("\r") ? String(lines[todo.line].dropLast()) : lines[todo.line]
        guard current == todo.source else { return nil }
        let indent = current.prefix { $0 == " " || $0 == "\t" }
        // Ticking a box changes only the box, so hand-written lines keep their wording.
        if updated.text == todo.text, updated.sceneID == todo.sceneID, updated.due == todo.due, updated.quote == todo.quote,
           let box = current.firstRange(of: /\[[ xX]\]/) {
            lines[todo.line] = current.replacingCharacters(in: box, with: updated.done ? "[x]" : "[ ]")
        } else {
            lines[todo.line] = indent + updated.markdown
        }
        return lines.joined(separator: "\n")
    }

    public static func toggling(_ todo: MarginTodo, in text: String) -> String? {
        var updated = todo
        updated.done.toggle()
        return replacing(todo, with: updated, in: text)
    }

    /// Removes a to-do's line. Returns nil if that line changed since it was read.
    public static func removing(_ todo: MarginTodo, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(todo.line), lines[todo.line].trimmingCharacters(in: .newlines) == todo.source else { return nil }
        lines.remove(at: todo.line)
        return lines.joined(separator: "\n")
    }

    /// Adds a to-do at the end of the file.
    public static func adding(_ todo: MarginTodo, to text: String) -> String {
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result + todo.markdown + "\n"
    }

    /// Open first (overdue, then by due date, then undated), then done.
    public static func sorted(_ todos: [MarginTodo], today: Date = .now) -> [MarginTodo] {
        todos.sorted { a, b in
            if a.done != b.done { return !a.done }
            let da = a.dueDate(), db = b.dueDate()
            switch (da, db) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.line < b.line
            }
        }
    }
}

/// A note or to-do that begins with `"quoted words" —` points at those words.
public enum MarginQuote {
    /// (quote, the rest). Accepts —, – or - after the closing quote.
    public static func split(_ text: String) -> (String?, String) {
        guard let match = text.firstMatch(of: /^["“](.+?)["”]\s*(?:—|–|-{1,2})\s*(.*)$/) else { return (nil, text) }
        return (String(match.1), String(match.2))
    }

    /// Where the quoted words are in a scene's text (case-insensitive), if anywhere.
    public static func range(of quote: String, in text: String, within scene: NSRange) -> NSRange? {
        let ns = text as NSString
        guard NSMaxRange(scene) <= ns.length else { return nil }
        let found = ns.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive], range: scene)
        return found.location == NSNotFound ? nil : found
    }
}
