import Foundation

/// The global word book, shared by every project:
/// `~/Library/Application Support/Slate/words.md`.
public enum GlobalWords {
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Slate", directoryHint: .isDirectory)
            .appending(path: "words.md")
    }
}

/// Merges every source of correct words into one ignore list for
/// `NSSpellChecker.setIgnoredWords` (SPEC: Spell check):
/// global words + project words + character names and aliases + the
/// screenplay terms. The system dictionary is the spell checker's own.
public enum SpellService {
    public static func ignoredWords(books: [[WordEntry]], characters: [String] = []) -> [String] {
        let dictionaryWords = books.flatMap { $0.flatMap(\.allForms) }
        return ScriptSpelling.ignoredWords(characters: characters, extra: dictionaryWords)
    }
}

/// Finds defined dictionary words (entries with an explanation or link)
/// in text: whole words, ignoring case, longest form first.
public struct TermMatcher: Sendable {
    public struct Hit: Sendable, Equatable {
        public let range: NSRange
        /// The entry's word (its key in the book).
        public let word: String
    }

    private let regex: NSRegularExpression?
    /// Folded form → entry word.
    private let lookup: [String: String]

    public static let empty = TermMatcher(entries: [])

    public init(entries: [WordEntry]) {
        var lookup: [String: String] = [:]
        for entry in entries where !entry.isSpellingOnly {
            for form in entry.allForms {
                let form = form.trimmingCharacters(in: .whitespaces)
                guard !form.isEmpty else { continue }
                let key = WordBook.fold(form)
                if lookup[key] == nil { lookup[key] = entry.word }
            }
        }
        self.lookup = lookup
        // Each form as written and folded, so "Zoë" in the book still matches "Zoe".
        var patterns = Set<String>()
        for entry in entries where !entry.isSpellingOnly {
            for form in entry.allForms where !form.trimmingCharacters(in: .whitespaces).isEmpty {
                let form = form.trimmingCharacters(in: .whitespaces)
                patterns.insert(form)
                patterns.insert(form.folding(options: [.diacriticInsensitive], locale: nil))
            }
        }
        let alternation = patterns
            .sorted { $0.utf16.count != $1.utf16.count ? $0.utf16.count > $1.utf16.count : $0 < $1 }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        regex = alternation.isEmpty ? nil : try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_'’])(?:"# + alternation + #")(?![\p{L}\p{N}_])"#,
            options: [.caseInsensitive]
        )
    }

    public var isEmpty: Bool { regex == nil }

    /// Hits in `range` (default: all of `text`), skipping any that touch `excluding`.
    public func matches(in text: String, range: NSRange? = nil, excluding: [NSRange] = []) -> [Hit] {
        guard let regex else { return [] }
        let ns = text as NSString
        let range = range ?? NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).compactMap { match in
            let found = match.range
            if excluding.contains(where: { NSIntersectionRange($0, found).length > 0 }) { return nil }
            guard let word = lookup[WordBook.fold(ns.substring(with: found))] else { return nil }
            return Hit(range: found, word: word)
        }
    }

    /// Ranges a term match must skip in Markdown or script text: `[[links]]`
    /// (the link already points somewhere) and scene tags.
    public static func protectedRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        return ScriptSpelling.linkPattern.matches(in: text, range: all).map(\.range)
            + sceneTagPattern.matches(in: text, range: all).map(\.range)
    }

    static let sceneTagPattern = try! NSRegularExpression(pattern: #"\{#[^}\n]*\}"#)
}

/// Where a dictionary word is used across the script and notes.
public enum TermUsage {
    /// Every use of `entry`'s word or forms in `texts` (path → contents),
    /// grouped by file in path order. The word books themselves are skipped.
    public static func uses(of entry: WordEntry, in texts: [(path: String, text: String)], limitPerFile: Int = 50) -> [ProjectSearch.FileResult] {
        var definedOnly = entry
        if definedOnly.isSpellingOnly { definedOnly.explanation = "-" }
        let matcher = TermMatcher(entries: [definedOnly])
        var results: [ProjectSearch.FileResult] = []
        for (path, text) in texts.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            guard path != WordBook.path, ProjectSearch.isSearchable(path) else { continue }
            let hits = matcher.matches(in: text, excluding: TermMatcher.protectedRanges(in: text)).prefix(limitPerFile)
            guard !hits.isEmpty else { continue }
            let lines = LineTable(text)
            let ns = text as NSString
            let matches = hits.map { hit -> ProjectSearch.Match in
                let line = lines.line(containing: hit.range.location)
                let lineRange = lines.range(ofLine: line)
                let (snippet, snippetRange) = ProjectSearch.makeSnippet(
                    ns.substring(with: lineRange),
                    match: NSRange(location: hit.range.location - lineRange.location, length: hit.range.length)
                )
                return ProjectSearch.Match(path: path, range: hit.range, line: line, snippet: snippet, snippetRange: snippetRange)
            }
            results.append(ProjectSearch.FileResult(path: path, matches: matches))
        }
        return results
    }
}
