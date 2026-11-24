import AppKit
import SlateCore

/// A misspelled word in a file: every place it appears, and a line to show.
struct Misspelling: Identifiable, Equatable {
    let word: String
    /// Every occurrence, in order (UTF-16 ranges in the file).
    var ranges: [NSRange]
    /// The line of the first occurrence (trimmed), and the word's range in it.
    var context: String
    var contextRange: NSRange
    /// The spell checker's suggestions, best first.
    var guesses: [String]

    var id: String { word }
    var count: Int { ranges.count }
}

/// Finds misspelled words in a whole file, skipping what the editors skip:
/// the project's ignore list (dictionary terms, character names and
/// aliases, learned and ignored words) through the shared document tag,
/// screenplay terms (V.O., O.S., CONT'D), scene IDs, markers, `[[links]]`,
/// and code in Markdown.
@MainActor
enum SpellingScan {
    enum Kind: Equatable {
        /// An act file: scene tags, line markers and links are skipped.
        case script
        /// A Markdown note, draft or word book. Frontmatter is skipped when its editor hides it.
        case markdown(skipsFrontmatter: Bool)
        case plain
    }

    static let maxGuesses = 6

    /// What kind of text `path` holds, as its editor treats it.
    static func kind(for path: String, text: String) -> Kind {
        let lower = path.lowercased()
        if lower.hasPrefix(ProjectLayout.script + "/"), Films.isActFile(path) { return .script }
        guard lower.hasSuffix(".md") || lower.hasSuffix(".markdown") else { return .plain }
        // Notes hide valid frontmatter behind the infobox; the draft and word book show it.
        let isNote = lower.hasPrefix(ProjectLayout.universe + "/") && path != ProjectLayout.draft
        return .markdown(skipsFrontmatter: isNote && Note(path: path, text: text).frontmatterError == nil)
    }

    /// Ranges never flagged in `text`.
    static func protectedRanges(in text: String, kind: Kind) -> [NSRange] {
        var ranges = TermMatcher.protectedRanges(in: text)
        switch kind {
        case .script:
            ranges += ScriptSpelling.protectedRanges(in: ScriptParser.parse(text), text: text)
        case .markdown(let skipsFrontmatter):
            ranges += MarkdownEditorController.protectedRanges(in: text)
            if skipsFrontmatter {
                let offset = Frontmatter.split(text).bodyOffset
                if offset > 0 { ranges.append(NSRange(location: 0, length: offset)) }
            }
        case .plain:
            break
        }
        return ranges
    }

    /// Makes sure the tag ignores `words`, keeping words ignored from an editor's
    /// context menu (Ignore Spelling) that aren't in the list.
    static func applyIgnoredWords(_ words: [String], tag: Int) {
        let checker = NSSpellChecker.shared
        let current = checker.ignoredWords(inSpellDocumentWithTag: tag) ?? []
        let have = Set(current)
        guard words.contains(where: { !have.contains($0) }) else { return }
        checker.setIgnoredWords(Array(have.union(words)), inSpellDocumentWithTag: tag)
    }

    /// Every misspelled word in `text`, in order of first appearance.
    static func misspellings(in text: String, kind: Kind, tag: Int, language: String) -> [Misspelling] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        let protected = protectedRanges(in: text, kind: kind)
        let language: String? = language.isEmpty ? nil : language
        var found: [String: Misspelling] = [:]
        var order: [String] = []
        var start = 0
        while start < ns.length {
            let range = checker.checkSpelling(of: text, startingAt: start, language: language, wrap: false,
                                              inSpellDocumentWithTag: tag, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0, range.location >= start else { break }
            start = NSMaxRange(range)
            if protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            let word = ns.substring(with: range)
            if ScriptSpelling.isScreenplayTerm(word) { continue }
            if found[word] != nil {
                found[word]?.ranges.append(range)
            } else {
                let (context, contextRange) = contextLine(around: range, in: ns)
                let guesses = checker.guesses(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: tag) ?? []
                found[word] = Misspelling(word: word, ranges: [range], context: context, contextRange: contextRange,
                                          guesses: Array(guesses.prefix(maxGuesses)))
                order.append(word)
            }
        }
        return order.compactMap { found[$0] }
    }

    /// The line around `range`, cut to about 90 characters, and where the word sits in it.
    static func contextLine(around range: NSRange, in text: NSString, width: Int = 90) -> (String, NSRange) {
        let line = text.lineRange(for: range)
        var start = line.location
        var end = NSMaxRange(line)
        while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
        while start < range.location, let scalar = UnicodeScalar(text.character(at: start)),
              CharacterSet.whitespaces.contains(scalar) { start += 1 }
        var prefix = "", suffix = ""
        let margin = max(0, (width - range.length) / 2)
        if range.location - start > margin {
            start = range.location - margin
            prefix = "…"
        }
        if end - NSMaxRange(range) > margin {
            end = NSMaxRange(range) + margin
            suffix = "…"
        }
        // Never cut an emoji or accented letter in half.
        let cut = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        start = cut.location
        end = NSMaxRange(cut)
        let body = text.substring(with: cut)
        let wordStart = (prefix as NSString).length + range.location - start
        return (prefix + body + suffix, NSRange(location: wordStart, length: range.length))
    }
}
