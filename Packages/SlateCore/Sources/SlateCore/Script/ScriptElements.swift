import Foundation

/// The kinds of line in a Slate script (Fountain rules plus `#` scene headings).
public enum ScriptElementKind: String, Sendable, CaseIterable, Codable {
    case sceneHeading
    case action
    case character
    case parenthetical
    case dialogue
    case transition
    /// `>THE END<`
    case centered
    /// `~lyric`
    case lyric
    /// `= synopsis`, left out of Publish.
    case synopsis
    /// `/* … */`, left out of Publish.
    case boneyard
    /// `===`
    case pageBreak
    case blank

    /// Character, parenthetical and dialogue: lines that belong to one speech.
    public var isSpeech: Bool {
        self == .character || self == .parenthetical || self == .dialogue
    }

    public var title: String {
        switch self {
        case .sceneHeading: "Scene Heading"
        case .action: "Action"
        case .character: "Character"
        case .parenthetical: "Parenthetical"
        case .dialogue: "Dialogue"
        case .transition: "Transition"
        case .centered: "Centered"
        case .lyric: "Lyric"
        case .synopsis: "Synopsis"
        case .boneyard: "Boneyard"
        case .pageBreak: "Page Break"
        case .blank: "Blank"
        }
    }
}

/// One line of a script file, classified.
public struct ScriptLine: Sendable, Equatable {
    public let index: Int
    public let kind: ScriptElementKind
    /// UTF-16 range of the line's text, without its line break.
    public let range: NSRange
    /// UTF-16 range including the line break (what paragraph styles cover).
    public let paragraphRange: NSRange
    public let text: String
    /// UTF-16 length of a leading marker that Publish drops: `# `, `.`, `!`,
    /// `@`, `>`, `~`, `=` (plus any whitespace before it).
    public let markerLength: Int
    /// Absolute UTF-16 range of a scene tag such as ` {#s014 dur=2:30}`,
    /// including the space before it.
    public let tagRange: NSRange?

    public var isEmpty: Bool { text.allSatisfy(\.isWhitespace) }
}

/// A scene: a heading and everything up to the next heading.
public struct ScriptScene: Sendable, Equatable, Identifiable {
    /// The stable ID from `{#s014}`, or nil if the heading has none yet.
    public let sceneID: String?
    /// The heading as printed: no marker, no tag. E.g. `INT. KITCHEN - NIGHT`.
    public let heading: String
    public let headingLine: Int
    /// Line indices from the heading up to (not including) the next heading.
    public let lines: Range<Int>
    /// UTF-16 range from the heading to the next heading (or the end).
    public let range: NSRange
    /// A `dur=` override from the tag, in seconds.
    public let durationOverride: TimeInterval?

    public var id: String { sceneID ?? "line-\(headingLine)" }
}

public struct ParsedScript: Sendable, Equatable {
    public let lines: [ScriptLine]
    public let scenes: [ScriptScene]

    public static let empty = ScriptParser.parse("")

    /// The line containing a UTF-16 location (the last line for the end).
    public func lineIndex(containing location: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].paragraphRange.location <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public func line(containing location: Int) -> ScriptLine? {
        lines.isEmpty ? nil : lines[lineIndex(containing: location)]
    }

    /// The scene containing a line, if the line is at or after the first heading.
    public func sceneIndex(containingLine line: Int) -> Int? {
        scenes.lastIndex { $0.headingLine <= line }
    }

    /// Cue names as written, upper-cased, without extensions: `MARA`, `OLDER MARA`.
    public var characterCues: [String] {
        lines.filter { $0.kind == .character }.compactMap { ScriptParser.characterName(fromCue: $0.text) }
    }
}
