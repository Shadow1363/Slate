import Foundation

/// Screenplay-aware spell check: what never counts as a misspelling.
/// `SpellService` adds the project's and global word books.
public enum ScriptSpelling {
    /// Abbreviations that appear in every script.
    public static let screenplayTerms: Set<String> = [
        "INT", "EXT", "EST", "I/E", "V.O", "O.S", "O.C", "CONT'D", "CONT", "POV", "OTS", "MOS", "SFX", "VFX",
        "EWS", "ELS", "WS", "LS", "MS", "MLS", "MCU", "CU", "ECU", "XCU", "INTERCUT", "SUPER", "B.G", "F.G",
        "V.O.", "O.S.", "O.C.", "B.G.", "F.G.",
    ]

    /// Words to hand `NSSpellChecker.setIgnoredWords`: character names and
    /// extra words such as the word books' entries (each word as written, in
    /// capitals and in title case, plus hyphenated words whole), and the
    /// screenplay terms.
    public static func ignoredWords(characters: [String], extra: [String] = []) -> [String] {
        var words = Set<String>()
        for name in characters + extra {
            let pieces = name.split(whereSeparator: \.isWhitespace).map(String.init)
            for word in pieces + pieces.flatMap({ $0.split(separator: "-").map(String.init) }) {
                let word = String(word)
                words.insert(word)
                words.insert(word.uppercased())
                words.insert(word.capitalized)
            }
        }
        words.formUnion(screenplayTerms)
        return words.sorted()
    }

    /// Ranges spell check must skip: scene tags, markers and `[[links]]`.
    public static func protectedRanges(in parsed: ParsedScript, text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        for line in parsed.lines {
            if let tag = line.tagRange { ranges.append(tag) }
            if line.markerLength > 0 { ranges.append(NSRange(location: line.range.location, length: line.markerLength)) }
        }
        let ns = text as NSString
        for match in linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            ranges.append(match.range)
        }
        return ranges
    }

    public static func isScreenplayTerm(_ word: String) -> Bool {
        screenplayTerms.contains(word.uppercased())
    }

    /// `[[Name]]` and `[[Name|shown text]]`.
    public static let linkPattern = try! NSRegularExpression(pattern: #"\[\[[^\[\]\n]*\]\]"#)

}

/// Names from character notes (`universe/characters/*.md`): the
/// frontmatter `name:` and `aliases:`, for autocomplete and spell check.
public enum CharacterNotes {
    public static func names(inNote text: String) -> [String] {
        guard let fields = try? Frontmatter.fields(in: text) else { return [] }
        let name = fields.first { $0.key == "name" }?.value.text ?? ""
        let aliases = fields.first { $0.key == "aliases" }?.value.items ?? []
        return ([name] + aliases).filter { !$0.isEmpty }
    }
}
