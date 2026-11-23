import Foundation

/// Find in Project (⇧⌘F): a plain scan of the project's text files.
///
/// There is no stored search index: a project is a few hundred small files,
/// and scanning them takes milliseconds. Matching ignores case and accents;
/// a query in double quotes matches that exact text (still ignoring case).
public enum ProjectSearch {
    public struct Match: Sendable, Equatable, Identifiable {
        public let path: String
        /// UTF-16 range in the file.
        public let range: NSRange
        /// 0-based line.
        public let line: Int
        /// The line, trimmed and shortened around the match.
        public let snippet: String
        /// Where the match sits inside `snippet` (UTF-16).
        public let snippetRange: NSRange

        public var id: String { "\(path)@\(range.location)" }
    }

    public struct FileResult: Sendable, Equatable, Identifiable {
        public let path: String
        public let matches: [Match]
        public var id: String { path }

        public init(path: String, matches: [Match]) {
            self.path = path
            self.matches = matches
        }
    }

    /// Searchable paths: text files outside `.slate/` and `exports/`.
    public static func isSearchable(_ path: String) -> Bool {
        !path.hasPrefix(".slate/") && !path.hasPrefix("exports/") && ProjectLayout.isTextFile(path)
    }

    /// Searches `texts` (path → contents), files in path order.
    public static func search(_ query: String, in texts: [(path: String, text: String)], limitPerFile: Int = 50) -> [FileResult] {
        let needle = needle(for: query)
        guard !needle.isEmpty else { return [] }
        var results: [FileResult] = []
        for (path, text) in texts.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let matches = search(needle, in: text, path: path, limit: limitPerFile)
            if !matches.isEmpty { results.append(FileResult(path: path, matches: matches)) }
        }
        return results
    }

    /// Reads every searchable file under `root`; `overrides` (open, unsaved
    /// buffers) replace what's on disk. Safe to call off the main actor.
    public static func search(_ query: String, root: URL, paths: [String], overrides: [String: String]) -> [FileResult] {
        let texts: [(path: String, text: String)] = paths.filter(isSearchable).compactMap { path in
            if let text = overrides[path] { return (path, text) }
            guard let data = try? Data(contentsOf: root.appending(path: path)),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return (path, text)
        }
        return search(query, in: texts)
    }

    static func needle(for query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    static func search(_ needle: String, in text: String, path: String, limit: Int) -> [Match] {
        let ns = text as NSString
        let lines = LineTable(text)
        var matches: [Match] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while matches.count < limit {
            let found = ns.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            let line = lines.line(containing: found.location)
            let lineRange = lines.range(ofLine: line)
            let (snippet, snippetRange) = makeSnippet(ns.substring(with: lineRange), match: NSRange(location: found.location - lineRange.location, length: found.length))
            matches.append(Match(path: path, range: found, line: line, snippet: snippet, snippetRange: snippetRange))
            searchRange = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
        }
        return matches
    }

    /// Trims a line to about 120 characters around the match.
    static func makeSnippet(_ line: String, match: NSRange) -> (String, NSRange) {
        let ns = line as NSString
        var start = 0
        while start < match.location, let scalar = UnicodeScalar(ns.character(at: start)), CharacterSet.whitespaces.contains(scalar) { start += 1 }
        var prefix = ""
        if match.location - start > 50 {
            start = match.location - 40
            // Don't split a surrogate pair.
            if start > 0, UTF16.isTrailSurrogate(ns.character(at: start)) { start -= 1 }
            prefix = "…"
        }
        var end = ns.length
        var suffix = ""
        if end - NSMaxRange(match) > 70 {
            end = NSMaxRange(match) + 60
            if end < ns.length, UTF16.isTrailSurrogate(ns.character(at: end)) { end += 1 }
            suffix = "…"
        }
        let body = ns.substring(with: NSRange(location: start, length: end - start)).trimmingTrailingWhitespace()
        let location = (prefix as NSString).length + match.location - start
        return (prefix + body + suffix, NSRange(location: location, length: match.length))
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var copy = self
        while copy.last?.isWhitespace == true { copy.removeLast() }
        return copy
    }
}

/// Quick Open (⌘P): fuzzy matching over notes, files and scenes.
public enum QuickOpen {
    public enum Kind: String, Sendable { case note, scene, file }

    public struct Item: Sendable, Equatable, Identifiable {
        public let kind: Kind
        public let title: String
        public let subtitle: String
        public let path: String
        /// The scene's row in the script navigator, for scenes.
        public let sceneRow: String?
        /// Other words that should match (aliases).
        public let keywords: [String]

        public var id: String { "\(kind.rawValue):\(path):\(sceneRow ?? ""):\(title)" }

        public init(kind: Kind, title: String, subtitle: String, path: String, sceneRow: String? = nil, keywords: [String] = []) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.path = path
            self.sceneRow = sceneRow
            self.keywords = keywords
        }
    }

    /// Items matching `query`, best first. An empty query keeps the order given.
    public static func rank(_ items: [Item], query: String, limit: Int = 50) -> [Item] {
        let query = LinkGraph.key(query)
        guard !query.isEmpty else { return Array(items.prefix(limit)) }
        let scored = items.enumerated().compactMap { index, item -> (Int, Int, Item)? in
            let candidates = [item.title] + item.keywords + [item.path]
            let best = candidates.enumerated().compactMap { position, text -> Int? in
                // Matches in the path count for less than in the title.
                score(query, in: LinkGraph.key(text)).map { position == candidates.count - 1 ? $0 / 2 : $0 }
            }.max()
            return best.map { ($0, index, item) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.prefix(limit).map(\.2)
    }

    /// Subsequence score: higher for contiguous runs, word starts and an
    /// early first match. Nil when `query` isn't a subsequence of `text`.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query)
        let t = Array(text)
        guard !q.isEmpty else { return 0 }
        if let range = text.range(of: query) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let wordStart = start == 0 || !t[start - 1].isLetter
            return 1000 - start + (wordStart ? 200 : 0) + (start == 0 && query.count == t.count ? 500 : 0)
        }
        var score = 0
        var qi = 0
        var previous = -2
        for (ti, char) in t.enumerated() where qi < q.count && char == q[qi] {
            score += 10
            if ti == previous + 1 { score += 15 }
            if ti == 0 || !t[ti - 1].isLetter { score += 20 }
            if qi == 0 { score -= min(ti, 30) }
            previous = ti
            qi += 1
        }
        return qi == q.count ? score : nil
    }
}
