import Foundation

/// Turns a script file into classified lines and scenes.
///
/// It follows the Fountain rules (https://fountain.io/syntax): a scene
/// heading is a line starting with `INT.`, `EXT.`, `INT./EXT.`, `I/E` or
/// `EST.` after a blank line, or any line forced with a leading `.`.
/// `#` lines are sections (acts, sequences), which never print.
/// Slate adds one thing: a scene tag such as `{#s014}` at the end of a
/// heading, which gives the scene a stable ID for the storyboard.
public enum ScriptParser {
    /// What the editor knows about the line being typed. An empty line can't
    /// say what it will become, and a character cue has no dialogue under it
    /// yet, so the editor passes a hint for the caret's line.
    public struct Hint: Sendable, Equatable {
        public var line: Int
        public var kind: ScriptElementKind

        public init(line: Int, kind: ScriptElementKind) {
            self.line = line
            self.kind = kind
        }
    }

    public static func parse(_ text: String, hint: Hint? = nil) -> ParsedScript {
        let ns = text as NSString
        let raw = splitLines(ns)
        let texts = raw.map { ns.substring(with: $0.content) }
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespaces) }

        var kinds: [ScriptElementKind] = []
        kinds.reserveCapacity(texts.count)
        var inBoneyard = false

        for i in texts.indices {
            let t = texts[i]
            let trim = trimmed[i]
            let previous: ScriptElementKind = i > 0 ? kinds[i - 1] : .blank
            let afterBlank = previous == .blank || previous == .pageBreak || previous == .section
            let hinted = hint?.line == i ? hint?.kind : nil
            let kind: ScriptElementKind

            if inBoneyard {
                kind = .boneyard
                if t.contains("*/") { inBoneyard = false }
            } else if trim.hasPrefix("/*") {
                kind = .boneyard
                if !trim.dropFirst(2).contains("*/") { inBoneyard = true }
            } else if trim.isEmpty {
                if let hinted {
                    kind = hinted
                } else if previous.isSpeech, previous != .character, t.count >= 2 {
                    // Fountain: two spaces keep a blank line inside dialogue.
                    kind = .dialogue
                } else {
                    kind = .blank
                }
            } else if trim.hasPrefix("===") {
                kind = .pageBreak
            } else if trim.hasPrefix("#") {
                kind = .section
            } else if trim.hasPrefix("."), !trim.hasPrefix(".."), trim.count > 1 {
                kind = .sceneHeading
            } else if trim.hasPrefix("!") {
                kind = .action
            } else if trim.hasPrefix("@") {
                kind = .character
            } else if trim.hasPrefix("~") {
                kind = .lyric
            } else if trim.hasPrefix("=") {
                kind = .synopsis
            } else if trim.hasPrefix(">"), trim.hasSuffix("<"), trim.count >= 2 {
                kind = .centered
            } else if trim.hasPrefix(">") {
                kind = .transition
            } else if previous.isSpeech {
                kind = trim.hasPrefix("(") ? .parenthetical : .dialogue
            } else if hinted == .character, isCharacterCue(trim) {
                kind = .character
            } else if hinted == .transition, !trim.contains(where: \.isLowercase) {
                kind = .transition
            } else if hinted == .sceneHeading {
                // Typed as a heading; the editor adds a `.` if it needs one
                // when the caret leaves the line.
                kind = .sceneHeading
            } else if afterBlank {
                if isHeading(trim) {
                    kind = .sceneHeading
                } else if isTransition(trim) {
                    kind = .transition
                } else if isCharacterCue(trim), speechFollows(i, trimmed: trimmed, hint: hint) {
                    kind = .character
                } else {
                    kind = .action
                }
            } else {
                kind = .action
            }
            kinds.append(kind)
        }

        var lines: [ScriptLine] = []
        lines.reserveCapacity(texts.count)
        var headingInfo: [Int: SceneHeading] = [:]
        for i in texts.indices {
            let kind = kinds[i]
            let content = raw[i].content
            var marker = 0
            var tag: NSRange?
            switch kind {
            case .sceneHeading:
                let info = SceneHeading.parse(texts[i])
                headingInfo[i] = info
                marker = info.markerLength
                tag = info.tagRange.map { NSRange(location: content.location + $0.location, length: $0.length) }
            case .action, .character, .lyric, .synopsis, .transition:
                marker = markerLength(texts[i], markers: kind.markers)
            case .centered:
                marker = markerLength(texts[i], markers: [">"])
            case .section:
                let leading = texts[i].prefix { $0 == " " || $0 == "\t" }
                let rest = texts[i].dropFirst(leading.count)
                let hashes = rest.prefix { $0 == "#" }
                let spaces = rest.dropFirst(hashes.count).prefix { $0 == " " || $0 == "\t" }
                marker = (leading + hashes + spaces).utf16.count
            default:
                break
            }
            lines.append(ScriptLine(
                index: i, kind: kind, range: content, paragraphRange: raw[i].paragraph,
                text: texts[i], markerLength: marker, tagRange: tag
            ))
        }

        let headingIndices = lines.indices.filter { kinds[$0] == .sceneHeading }
        var scenes: [ScriptScene] = []
        for (n, start) in headingIndices.enumerated() {
            let end = n + 1 < headingIndices.count ? headingIndices[n + 1] : lines.count
            let startLocation = lines[start].paragraphRange.location
            let endLocation = end < lines.count ? lines[end].paragraphRange.location : ns.length
            let info = headingInfo[start] ?? SceneHeading.parse(texts[start])
            scenes.append(ScriptScene(
                sceneID: info.sceneID,
                heading: info.heading,
                headingLine: start,
                lines: start..<end,
                range: NSRange(location: startLocation, length: endLocation - startLocation),
                durationOverride: info.duration
            ))
        }
        return ParsedScript(lines: lines, scenes: scenes)
    }

    // MARK: - Rules

    /// `INT.`, `EXT.`, `INT./EXT.`, `INT/EXT`, `I/E`, `EST.` followed by `.` or a space.
    public static func isHeading(_ text: String) -> Bool {
        let upper = text.uppercased()
        for prefix in ["INT./EXT", "INT/EXT", "I/E", "INT", "EXT", "EST"] where upper.hasPrefix(prefix) {
            let rest = upper.dropFirst(prefix.count)
            if let next = rest.first, next == "." || next == " " { return true }
        }
        return false
    }

    /// All caps and ending in `TO:`.
    public static func isTransition(_ text: String) -> Bool {
        !text.contains(where: \.isLowercase) && text.hasSuffix("TO:")
    }

    /// An all-caps name, optionally with an extension: `MARA`, `MARA (V.O.)`,
    /// `OLDER MARA (cont'd)`, `MARA ^` (dual dialogue).
    public static func isCharacterCue(_ text: String) -> Bool {
        guard let name = characterName(fromCue: text, uppercase: false) else { return false }
        return name.contains(where: \.isLetter) && !name.contains(where: \.isLowercase) && !name.hasSuffix(":")
    }

    /// The name part of a cue, upper-cased: `@Mara (V.O.) ^` → `MARA`.
    public static func characterName(fromCue cue: String, uppercase: Bool = true) -> String? {
        var text = cue.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("@") { text.removeFirst() }
        if text.hasSuffix("^") { text.removeLast() }
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return uppercase ? text.uppercased() : text
    }

    private static func speechFollows(_ i: Int, trimmed: [String], hint: Hint?) -> Bool {
        let next = i + 1
        guard next < trimmed.count else { return false }
        if !trimmed[next].isEmpty { return true }
        if let hint, hint.line == next, hint.kind == .dialogue || hint.kind == .parenthetical { return true }
        return false
    }

    private static func markerLength(_ text: String, markers: [Character]) -> Int {
        let leading = text.prefix { $0 == " " || $0 == "\t" }
        guard let first = text.dropFirst(leading.count).first, markers.contains(first) else { return 0 }
        return leading.utf16.count + 1
    }

    // MARK: - Lines

    struct RawLine {
        let content: NSRange
        let paragraph: NSRange
    }

    /// Splits on `\n`, `\r\n` and `\r`. A trailing line break yields a final empty line.
    static func splitLines(_ ns: NSString) -> [RawLine] {
        var result: [RawLine] = []
        let length = ns.length
        var start = 0
        while start < length {
            var end = start
            var contentsEnd = start
            ns.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            result.append(RawLine(
                content: NSRange(location: start, length: contentsEnd - start),
                paragraph: NSRange(location: start, length: end - start)
            ))
            start = end
        }
        if length == 0 || result.last.map({ $0.paragraph.length > $0.content.length }) == true {
            result.append(RawLine(content: NSRange(location: length, length: 0), paragraph: NSRange(location: length, length: 0)))
        }
        return result
    }
}

private extension ScriptElementKind {
    var markers: [Character] {
        switch self {
        case .action: ["!"]
        case .character: ["@"]
        case .lyric: ["~"]
        case .synopsis: ["="]
        case .transition: [">"]
        default: []
        }
    }
}

/// The parts of a scene heading line: `INT. KITCHEN - NIGHT #14# {#s014 dur=2:30}`.
public struct SceneHeading: Sendable, Equatable {
    /// UTF-16 length of a forcing `.` at the start (with leading whitespace).
    public let markerLength: Int
    /// The heading as printed: `INT. KITCHEN - NIGHT`.
    public let heading: String
    public let sceneID: String?
    /// Tag attributes (`dur=2:30`). A Fountain scene number (`#14#`) is
    /// stored as `number`.
    public let attributes: [String: String]
    /// Range of the tag within the line, including whitespace before it.
    public let tagRange: NSRange?

    public var duration: TimeInterval? {
        attributes["dur"].flatMap(SceneHeading.parseDuration)
    }

    /// `INT. KITCHEN` → (`INT.`, `KITCHEN`, nil); `EXT. ROOF - DAY` → (`EXT.`, `ROOF`, `DAY`).
    public var parts: (prefix: String?, location: String, time: String?) {
        var rest = heading
        var prefix: String?
        let upper = heading.uppercased()
        for candidate in ["INT./EXT.", "INT/EXT.", "INT./EXT", "INT/EXT", "I/E.", "I/E", "INT.", "EXT.", "EST.", "INT", "EXT", "EST"]
        where upper.hasPrefix(candidate) {
            let after = upper.dropFirst(candidate.count)
            if after.isEmpty || after.first == " " {
                prefix = String(heading.prefix(candidate.count))
                rest = String(heading.dropFirst(candidate.count))
                break
            }
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if let dash = rest.range(of: " - ", options: .backwards) {
            let location = String(rest[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let time = String(rest[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (prefix, location, time.isEmpty ? nil : time)
        }
        return (prefix, rest, nil)
    }

    public static func parse(_ line: String) -> SceneHeading {
        let ns = line as NSString
        var marker = 0
        let leading = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
        let afterLeading = ns.substring(from: leading)
        if afterLeading.hasPrefix("."), !afterLeading.hasPrefix("..") {
            marker = leading + 1
        }

        var body = ns.substring(from: marker)
        var sceneID: String?
        var attributes: [String: String] = [:]
        var tagRange: NSRange?

        let bodyNS = body as NSString
        if let match = tagPattern.firstMatch(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
            sceneID = bodyNS.substring(with: match.range(at: 1))
            let attributeText = bodyNS.substring(with: match.range(at: 2))
            for pair in attributeText.split(whereSeparator: \.isWhitespace) {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { attributes[String(parts[0])] = String(parts[1]) }
            }
            tagRange = NSRange(location: marker + match.range.location, length: match.range.length)
            body = bodyNS.substring(to: match.range.location)
        }
        let numberNS = body as NSString
        if let match = numberPattern.firstMatch(in: body, range: NSRange(location: 0, length: numberNS.length)) {
            if attributes["number"] == nil { attributes["number"] = numberNS.substring(with: match.range(at: 1)) }
            body = numberNS.substring(to: match.range.location)
        }
        return SceneHeading(
            markerLength: marker,
            heading: body.trimmingCharacters(in: .whitespaces),
            sceneID: sceneID,
            attributes: attributes,
            tagRange: tagRange
        )
    }

    /// `2:30` → 150, `90` → 90, `1:02:00` → 3720.
    public static func parseDuration(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    /// Fountain's scene number at the end of a heading: ` #14#`, ` #1A#`.
    public static let numberPattern = try! NSRegularExpression(pattern: #"\s*#([A-Za-z0-9.-]+)#\s*$"#)

    /// ` {#s014}` or ` {#s014 dur=2:30}` at the end of the line.
    static let tagPattern = try! NSRegularExpression(
        pattern: #"\s*\{#([A-Za-z0-9][A-Za-z0-9_-]*)((?:\s+[A-Za-z]+=[^\s}]*)*)\s*\}\s*$"#
    )
}
