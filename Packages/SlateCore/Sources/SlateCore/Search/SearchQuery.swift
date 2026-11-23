import Foundation

/// A parsed Search query: `!c juno #good role:lead "always empty"`.
///
/// - `!name` anywhere is a bang (an unknown one is just a word). `/` at the start means `!text`.
/// - `#tag` must be on the result.
/// - `key:value` filters on a field (`int:` with no value means "has it").
/// - Anything in double quotes is matched exactly.
/// - After `!film`, the next word names the film (`film:` filter).
/// - With `!t`, plain words are tags too.
public struct SearchQuery: Sendable, Equatable {
    public struct Filter: Sendable, Equatable {
        public let key: String
        public let value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var scopes: [SearchScope] = []
    public var tags: [String] = []
    public var filters: [Filter] = []
    /// The words left over, joined by spaces.
    public var text = ""
    /// Words that were in quotes (exact matches).
    public var exact: [String] = []
    /// The token being typed, when it starts with `!` or `#` (for suggestions).
    public var partial: String?

    public var isEmpty: Bool { scopes.isEmpty && tags.isEmpty && filters.isEmpty && text.isEmpty && exact.isEmpty }
    public func has(_ scope: SearchScope) -> Bool { scopes.contains(scope) }
    public func filter(_ key: String) -> Filter? { filters.first { $0.key == key } }

    public init() {}

    public static func parse(_ raw: String, bangs: [Bang]) -> SearchQuery {
        var query = SearchQuery()
        let byName = Dictionary(bangs.map { ($0.name, $0.scope) }, uniquingKeysWith: { a, _ in a })
        var input = raw
        if input.hasPrefix("/") {
            query.scopes.append(.text)
            input.removeFirst()
        }
        var words: [String] = []
        var takeFilm = false
        let tokens = tokenize(input)
        for (index, token) in tokens.enumerated() {
            let isLast = index == tokens.count - 1 && !raw.hasSuffix(" ")
            if token.quoted {
                query.exact.append(token.text)
                continue
            }
            let text = token.text
            if text.hasPrefix("!") {
                let name = Bangs.normalize(text)
                if let scope = byName[name] {
                    if !query.scopes.contains(scope) { query.scopes.append(scope) }
                    if scope == .film { takeFilm = true }
                    continue
                }
                if isLast { query.partial = text }
                if name.isEmpty { continue }
            } else if text.hasPrefix("#"), text.count > 1 {
                query.tags.append(Tags.normalize(text))
                if isLast { query.partial = text }
                continue
            } else if text == "#" {
                if isLast { query.partial = text }
                continue
            } else if let colon = text.firstIndex(of: ":"), colon != text.startIndex,
                      text[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                      !text.contains("//") {
                query.filters.append(Filter(key: text[..<colon].lowercased(), value: String(text[text.index(after: colon)...])))
                continue
            }
            if takeFilm {
                query.filters.append(Filter(key: "film", value: text))
                takeFilm = false
                continue
            }
            words.append(text)
        }
        if query.has(.tag) {
            query.tags += words.map(Tags.normalize)
            words = []
        }
        query.text = words.joined(separator: " ")
        return query
    }

    /// Words and "quoted phrases".
    static func tokenize(_ text: String) -> [(text: String, quoted: Bool)] {
        var tokens: [(String, Bool)] = []
        var current = ""
        var inQuotes = false
        for char in text {
            if char == "\"" || char == "“" || char == "”" {
                if inQuotes {
                    if !current.isEmpty { tokens.append((current, true)) }
                    current = ""
                    inQuotes = false
                } else {
                    if !current.isEmpty { tokens.append((current, false)) }
                    current = ""
                    inQuotes = true
                }
            } else if char.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append((current, false)) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append((current, inQuotes)) }
        return tokens
    }
}
