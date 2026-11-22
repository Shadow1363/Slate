import Foundation

/// Type-ahead for character cues and scene headings.
public enum ScriptCompletion {
    public static let headingPrefixes = ["INT. ", "EXT. ", "INT./EXT. ", "EST. "]
    public static let standardTimes = ["DAY", "NIGHT", "CONTINUOUS", "LATER", "MOMENTS LATER", "MORNING", "EVENING", "DAWN", "DUSK", "SAME"]
    public static let cueExtensions = ["V.O.)", "O.S.)", "O.C.)", "CONT'D)"]

    public struct Sources: Sendable, Equatable {
        public var characters: [String]
        public var locations: [String]
        public var times: [String]

        public init(characters: [String] = [], locations: [String] = [], times: [String] = []) {
            self.characters = characters
            self.locations = locations
            self.times = times
        }
    }

    /// The rest of the word to offer after `typed` (the line up to the
    /// caret), or nil. Matching ignores case; the result is upper-case.
    public static func completion(afterTyping typed: String, in kind: ScriptElementKind, sources: Sources) -> String? {
        switch kind {
        case .character: characterCompletion(typed, sources: sources)
        case .sceneHeading: headingCompletion(typed, sources: sources)
        default: nil
        }
    }

    static func characterCompletion(_ typed: String, sources: Sources) -> String? {
        var text = typed
        if text.hasPrefix("@") { text.removeFirst() }
        if let paren = text.lastIndex(of: "(") {
            let partial = String(text[text.index(after: paren)...]).uppercased()
            guard !partial.isEmpty, !partial.contains(")") else { return nil }
            return remainder(of: partial, among: cueExtensions)
        }
        let upper = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !upper.isEmpty, upper == text.uppercased() else { return nil }
        return remainder(of: upper, among: sources.characters)
    }

    static func headingCompletion(_ typed: String, sources: Sources) -> String? {
        var body = typed
        if body.hasPrefix("."), !body.hasPrefix("..") {
            body = String(body.dropFirst())
        }
        let upper = body.uppercased()
        guard !upper.isEmpty else { return nil }

        guard let prefix = headingPrefixes.first(where: { upper.hasPrefix($0) }) else {
            return remainder(of: upper, among: headingPrefixes)
        }
        let rest = String(upper.dropFirst(prefix.count))
        if let dash = rest.range(of: " - ", options: .backwards) {
            let time = String(rest[dash.upperBound...])
            guard !time.isEmpty else { return nil }
            return remainder(of: time, among: sources.times + standardTimes)
        }
        guard !rest.isEmpty else { return nil }
        return remainder(of: rest, among: sources.locations)
    }

    private static func remainder(of partial: String, among candidates: [String]) -> String? {
        for candidate in candidates {
            let upper = candidate.uppercased()
            if upper.hasPrefix(partial), upper.count > partial.count {
                return String(upper.dropFirst(partial.count))
            }
        }
        return nil
    }
}
