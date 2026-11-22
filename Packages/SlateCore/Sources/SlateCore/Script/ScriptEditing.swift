import Foundation

/// The editing rules behind Tab and Return, kept free of UI so they're tested.
///
/// Return (caret at the end of a line), as in Final Draft:
/// Scene Heading → Action, Action → Action, Character → Dialogue,
/// Parenthetical → Dialogue, Dialogue → Action, Transition → Scene Heading.
/// Tab cycles a line between Action → Character → Transition → Scene
/// Heading, or inside a speech between Dialogue ↔ Parenthetical.
public enum ScriptEditing {
    public struct ReturnPlan: Equatable, Sendable {
        /// Text to insert at the caret ("" changes the current line in place).
        public let insert: String
        /// What the line the caret lands on becomes.
        public let next: ScriptElementKind
    }

    /// nil means "insert an ordinary line break".
    public static func returnPlan(for kind: ScriptElementKind, lineIsEmpty: Bool) -> ReturnPlan? {
        if lineIsEmpty {
            switch kind {
            case .sceneHeading, .character, .transition: return ReturnPlan(insert: "", next: .action)
            case .parenthetical: return ReturnPlan(insert: "", next: .dialogue)
            case .dialogue: return ReturnPlan(insert: "\n", next: .action)
            case .action: return ReturnPlan(insert: "\n", next: .action)
            default: return nil
            }
        }
        switch kind {
        case .sceneHeading, .action, .dialogue, .lyric, .centered: return ReturnPlan(insert: "\n\n", next: .action)
        case .character, .parenthetical: return ReturnPlan(insert: "\n", next: .dialogue)
        case .transition: return ReturnPlan(insert: "\n\n", next: .sceneHeading)
        default: return nil
        }
    }

    static let outerCycle: [ScriptElementKind] = [.action, .character, .transition, .sceneHeading]
    static let speechCycle: [ScriptElementKind] = [.dialogue, .parenthetical]

    /// The kind Tab (or Shift-Tab) turns a line into, or nil if Tab does nothing here.
    /// - Parameter inSpeech: The line directly follows a character, parenthetical or dialogue line.
    public static func tab(from kind: ScriptElementKind, inSpeech: Bool, forward: Bool) -> ScriptElementKind? {
        let current = kind == .blank ? (inSpeech ? .dialogue : .action) : kind
        let cycle = inSpeech || current == .dialogue || current == .parenthetical ? speechCycle : outerCycle
        guard let index = cycle.firstIndex(of: current) else { return nil }
        let step = forward ? 1 : cycle.count - 1
        return cycle[(index + step) % cycle.count]
    }

    /// Rewrites a line's text so the parser reads it as `kind`. Scene tags
    /// are dropped when a heading becomes something else.
    public static func convert(_ line: String, to kind: ScriptElementKind) -> String {
        let base = plainText(of: line)
        switch kind {
        case .sceneHeading:
            let upper = base.uppercased()
            return upper.isEmpty || ScriptParser.isHeading(upper) ? upper : "." + upper
        case .character:
            let upper = base.uppercased()
            return upper.isEmpty || ScriptParser.isCharacterCue(upper) ? upper : "@" + upper
        case .transition:
            let upper = base.uppercased()
            return ScriptParser.isTransition(upper) ? upper : ">" + upper
        case .parenthetical:
            if base.hasPrefix("(") { return base }
            return "(" + base + ")"
        case .dialogue:
            var text = base
            if text.hasPrefix("(") { text.removeFirst() }
            if text.hasSuffix(")") { text.removeLast() }
            return text
        case .action:
            if ScriptParser.isHeading(base) || ScriptParser.isTransition(base) || ScriptParser.isCharacterCue(base) {
                return "!" + base
            }
            return base
        default:
            return base
        }
    }

    /// A line without its marker or scene tag.
    static func plainText(of line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if (text.hasPrefix(".") && !text.hasPrefix("..")) || ScriptParser.isHeading(text) {
            text = SceneHeading.parse(text).heading
        } else if let first = text.first, "!@>~".contains(first) {
            text.removeFirst()
            if first == ">", text.hasSuffix("<") { text.removeLast() }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Text typed into an empty line of this kind starts with this marker,
    /// so the file reads back as the same kind.
    public static func marker(forTypingInto kind: ScriptElementKind) -> String {
        switch kind {
        case .transition: ">"
        default: ""
        }
    }

    /// Kinds whose text is typed in capitals.
    public static func typesInCapitals(_ kind: ScriptElementKind) -> Bool {
        kind == .sceneHeading || kind == .character || kind == .transition
    }

    /// The edit that finishes a heading line once the caret leaves it: capitals,
    /// plus a `.` in front when Fountain wouldn't recognise it on its own (no
    /// `INT.`/`EXT.`, or no blank line above), or no `.` when it would.
    /// The scene tag is left alone. Nil if the line is fine as it is.
    public static func headingMarkerEdit(in parsed: ParsedScript, line index: Int) -> TagEdit? {
        guard parsed.lines.indices.contains(index), parsed.lines[index].kind == .sceneHeading else { return nil }
        let line = parsed.lines[index]
        let ns = line.text as NSString
        let leading = line.text.prefix { $0 == " " || $0 == "\t" }.utf16.count
        let end = line.tagRange.map { $0.location - line.range.location } ?? ns.length
        guard end > leading else { return nil }
        let region = NSRange(location: leading, length: end - leading)
        let body = ns.substring(with: region)
        let forced = body.hasPrefix(".") && !body.hasPrefix("..")
        let plain = forced ? String(body.dropFirst()) : body
        guard !plain.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let previous = index > 0 ? parsed.lines[index - 1].kind : .blank
        let detectable = previous == .blank || previous == .pageBreak || previous == .section
        let recognised = detectable && ScriptParser.isHeading(plain)
        let fixed = (recognised ? "" : ".") + plain.uppercased()
        guard fixed != body else { return nil }
        return TagEdit(
            range: NSRange(location: line.range.location + region.location, length: region.length),
            replacement: fixed,
            sceneID: SceneHeading.parse(line.text).sceneID ?? ""
        )
    }

    /// An edit that gives a heading its scene tag.
    public struct TagEdit: Equatable, Sendable {
        /// Empty to insert at the end of the heading, or the old tag to replace.
        public let range: NSRange
        public let replacement: String
        public let sceneID: String
    }

    /// Tags for headings that have none, or whose ID repeats an earlier
    /// heading's (a pasted scene). In ascending order of location.
    /// - Parameters:
    ///   - existing: IDs used elsewhere in the script (other act files).
    ///   - onlyLine: Limit to the heading on this line.
    public static func missingSceneTags(in parsed: ParsedScript, existing: Set<String>, onlyLine: Int? = nil) -> [TagEdit] {
        var used = existing.union(parsed.scenes.compactMap(\.sceneID))
        var seen: Set<String> = []
        var result: [TagEdit] = []
        for scene in parsed.scenes {
            if let id = scene.sceneID, !seen.contains(id) {
                seen.insert(id)
                continue
            }
            guard onlyLine == nil || onlyLine == scene.headingLine, !scene.heading.isEmpty else { continue }
            let line = parsed.lines[scene.headingLine]
            let id = ScriptBook.nextSceneID(existing: used)
            used.insert(id)
            if let tag = line.tagRange {
                result.append(TagEdit(range: tag, replacement: " {#\(id)}", sceneID: id))
            } else {
                let needsSpace = !(line.text.last?.isWhitespace ?? true)
                result.append(TagEdit(
                    range: NSRange(location: line.range.upperBound, length: 0),
                    replacement: (needsSpace ? " " : "") + "{#\(id)}",
                    sceneID: id
                ))
            }
        }
        return result
    }

    /// Gives every heading a unique scene tag (used by import and tests).
    public static func assigningSceneIDs(to text: String, existing: Set<String> = []) -> String {
        let ns = NSMutableString(string: text)
        for edit in missingSceneTags(in: ScriptParser.parse(text), existing: existing).reversed() {
            ns.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return ns as String
    }

    /// Moves scene `from` so it lands before the scene now at `to` (SwiftUI
    /// `onMove` offsets). Text before the first heading stays put. Each
    /// scene ends with one blank line after the move.
    public static func movingScene(in text: String, from: Int, to: Int) -> String {
        let parsed = ScriptParser.parse(text)
        let ns = text as NSString
        guard parsed.scenes.indices.contains(from), to >= 0, to <= parsed.scenes.count, to != from, to != from + 1 else {
            return text
        }
        let preamble = ns.substring(to: parsed.scenes[0].range.location)
        var blocks = parsed.scenes.map { scene -> String in
            var block = ns.substring(with: scene.range)
            while let last = block.last, last.isNewline || last == " " || last == "\t" { block.removeLast() }
            return block + "\n\n"
        }
        let moved = blocks.remove(at: from)
        blocks.insert(moved, at: to > from ? to - 1 : to)
        var result = preamble + blocks.joined()
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }
}
