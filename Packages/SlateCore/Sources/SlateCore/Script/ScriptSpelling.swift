import Foundation

/// Screenplay-aware spell check: what never counts as a misspelling.
/// (Milestone 6 adds the project's dictionary terms and global words.)
public enum ScriptSpelling {
    /// Abbreviations that appear in every script.
    public static let screenplayTerms: Set<String> = [
        "INT", "EXT", "EST", "I/E", "V.O", "O.S", "O.C", "CONT'D", "CONT", "POV", "OTS", "MOS", "SFX", "VFX",
        "EWS", "ELS", "WS", "LS", "MS", "MLS", "MCU", "CU", "ECU", "XCU", "INTERCUT", "SUPER", "B.G", "F.G",
        "V.O.", "O.S.", "O.C.", "B.G.", "F.G.",
    ]

    /// Words to hand `NSSpellChecker.setIgnoredWords`: character names (each
    /// word, in capitals and in title case), extra words such as
    /// `dictionary/words.txt`, and the screenplay terms.
    public static func ignoredWords(characters: [String], extra: [String] = []) -> [String] {
        var words = Set<String>()
        for name in characters + extra {
            for word in name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }) {
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

    /// `dictionary/words.txt`: one word per line; blank lines and `#` comments skipped.
    public static func words(fromWordList text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

/// Reads names from character notes (`universe/characters/*.md`) without a
/// full YAML parser: just `name:` and `aliases:` in the frontmatter.
public enum CharacterNotes {
    public static func names(inNote text: String) -> [String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        var names: [String] = []
        var inAliasList = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { break }
            if inAliasList {
                if trimmed.hasPrefix("- ") {
                    names.append(unquote(String(trimmed.dropFirst(2))))
                    continue
                }
                inAliasList = false
            }
            if let value = value(of: "name", in: trimmed) {
                if !value.isEmpty { names.append(unquote(value)) }
            } else if let value = value(of: "aliases", in: trimmed) {
                if value.hasPrefix("[") {
                    let inner = value.dropFirst().prefix { $0 != "]" }
                    names += inner.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                } else if value.isEmpty {
                    inAliasList = true
                } else {
                    names.append(unquote(value))
                }
            }
        }
        return names.filter { !$0.isEmpty }
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
    }

    private static func unquote(_ text: String) -> String {
        var text = text
        if text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
