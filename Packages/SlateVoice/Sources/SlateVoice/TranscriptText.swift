import Foundation

/// Tidying a transcript and fitting it into existing text.
public enum TranscriptText {
    /// Whisper's non-speech markers: `[BLANK_AUDIO]`, `[Music]`, `(wind blowing)`, `*laughs*`.
    private static let markers = try! NSRegularExpression(pattern: #"\[[^\]]*\]|\((?:[a-z ]+)\)|\*[^*]+\*"#,
                                                          options: [.caseInsensitive])

    /// Trims, drops non-speech markers and collapses runs of spaces. Paragraph
    /// breaks (blank lines) are kept.
    public static func clean(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        let stripped = markers.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
        let paragraphs = stripped
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n\n")
    }

    /// `text` as it should be inserted after `preceding` (the text before the
    /// cursor) and before `following`: a space added where it would run into
    /// a word, and the first letter capitalized at the start of the text, a
    /// line or a sentence.
    public static func insertion(_ text: String, preceding: Substring, following: Character?) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        let lastVisible = preceding.last { !($0.isWhitespace && !$0.isNewline) }
        let startsSentence = lastVisible.map { $0.isNewline || ".!?".contains($0) } ?? true
        if startsSentence, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        if let before = preceding.last, !before.isWhitespace, !"([{\"'“‘".contains(before),
           let first = result.first, first.isLetter || first.isNumber {
            result = " " + result
        }
        if let following, following.isLetter || following.isNumber, let last = result.last, !last.isWhitespace {
            result += " "
        }
        return result
    }

    /// A title for a voice note: the first sentence, up to 8 words.
    public static func title(from transcript: String, fallback: String) -> String {
        let firstSentence = transcript.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? ""
        let words = firstSentence.split(whereSeparator: \.isWhitespace).prefix(8)
        let title = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return title.isEmpty ? fallback : title
    }
}
