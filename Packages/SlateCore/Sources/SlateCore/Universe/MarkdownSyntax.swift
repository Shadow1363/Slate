import Foundation

/// A fast line-by-line Markdown scanner for live styling in the editor.
///
/// It only has to look right while typing, so it is deliberately simpler
/// than CommonMark (swift-markdown handles the outline, links and search).
/// Ranges are UTF-16 and relative to the line.
public enum MarkdownSyntax {
    public enum LineKind: Equatable, Sendable {
        case text
        case blank
        case heading(Int)
        case quote
        case listItem
        case task(done: Bool)
        /// A ``` or ~~~ fence line.
        case fence
        /// A line inside a fenced block.
        case code
        /// `---`, `***`, `___`.
        case rule
    }

    public enum SpanKind: Equatable, Sendable {
        /// Syntax characters to dim: `#`, `**`, `[[`, `]]`, `>`, `-`.
        case marker
        case bold
        case italic
        case strike
        case code
        /// A `[[link]]`; `target` is what it points at.
        case link(target: String)
    }

    public struct Span: Equatable, Sendable {
        public let kind: SpanKind
        public let range: NSRange
    }

    public struct Line: Equatable, Sendable {
        public let kind: LineKind
        public let spans: [Span]
    }

    /// Scans one line. `inFence` says whether a fenced block is open above
    /// it; the result says whether one is open after it.
    public static func scan(line: String, inFence: Bool) -> (line: Line, inFence: Bool) {
        let ns = line as NSString
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        if inFence {
            return isFence
                ? (Line(kind: .fence, spans: [Span(kind: .marker, range: NSRange(location: 0, length: ns.length))]), false)
                : (Line(kind: .code, spans: []), true)
        }
        if isFence {
            return (Line(kind: .fence, spans: [Span(kind: .marker, range: NSRange(location: 0, length: ns.length))]), true)
        }
        if trimmed.isEmpty { return (Line(kind: .blank, spans: []), false) }

        var spans: [Span] = []
        var kind = LineKind.text
        var contentStart = 0
        let indent = line.prefix { $0 == " " || $0 == "\t" }.utf16.count

        if let match = line.firstMatch(of: /^(#{1,6})(\s+|$)/) {
            let level = match.1.count
            kind = .heading(level)
            contentStart = match.0.utf16.count
            spans.append(Span(kind: .marker, range: NSRange(location: 0, length: level)))
        } else if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) || trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 3 {
            return (Line(kind: .rule, spans: [Span(kind: .marker, range: NSRange(location: 0, length: ns.length))]), false)
        } else if let match = line.firstMatch(of: /^\s*>\s?/) {
            kind = .quote
            contentStart = match.0.utf16.count
            spans.append(Span(kind: .marker, range: NSRange(location: 0, length: contentStart)))
        } else if let match = line.firstMatch(of: /^\s*[-*+]\s+\[([ xX])\]\s/) {
            kind = .task(done: match.1 != " ")
            contentStart = match.0.utf16.count
            spans.append(Span(kind: .marker, range: NSRange(location: indent, length: contentStart - indent)))
        } else if let match = line.firstMatch(of: /^\s*([-*+]|\d{1,9}[.)])\s/) {
            kind = .listItem
            contentStart = match.0.utf16.count
            spans.append(Span(kind: .marker, range: NSRange(location: indent, length: contentStart - indent)))
        }

        spans += inlineSpans(in: line, from: contentStart)
        return (Line(kind: kind, spans: spans), false)
    }

    /// Scans a whole text.
    public static func scan(_ text: String) -> [Line] {
        var inFence = false
        return text.components(separatedBy: "\n").map { line in
            let result = scan(line: line, inFence: inFence)
            inFence = result.inFence
            return result.line
        }
    }

    // MARK: - Inline

    private static let patterns: [(NSRegularExpression, SpanKind, Int)] = {
        func make(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
        return [
            (make(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#), .bold, 2),
            (make(#"(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])"#), .bold, 2),
            (make(#"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#), .italic, 1),
            (make(#"(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])"#), .italic, 1),
            (make(#"~~(?=\S)(.+?)(?<=\S)~~"#), .strike, 2),
        ]
    }()

    static func inlineSpans(in line: String, from start: Int) -> [Span] {
        let ns = line as NSString
        var spans: [Span] = []
        var taken: [NSRange] = []

        // Code first: nothing inside it is styled.
        for code in MarkdownOutline.inlineCodeSpans(in: line) where code.location >= start {
            spans.append(Span(kind: .code, range: code))
            taken.append(code)
        }
        for link in WikiLink.find(in: line, excluding: taken) where link.range.location >= start {
            spans.append(Span(kind: .link(target: link.target), range: link.range))
            spans.append(Span(kind: .marker, range: NSRange(location: link.range.location, length: 2)))
            spans.append(Span(kind: .marker, range: NSRange(location: NSMaxRange(link.range) - 2, length: 2)))
            if link.shown != nil {
                // Dim `Target|`, keep the shown text bright.
                let inner = (ns.substring(with: link.range) as NSString)
                let bar = inner.range(of: "|")
                if bar.location != NSNotFound {
                    spans.append(Span(kind: .marker, range: NSRange(location: link.range.location + 2, length: bar.location - 1)))
                }
            }
            taken.append(link.range)
        }
        for (regex, kind, markerLength) in patterns {
            for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range
                guard range.location >= start, !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                spans.append(Span(kind: kind, range: range))
                spans.append(Span(kind: .marker, range: NSRange(location: range.location, length: markerLength)))
                spans.append(Span(kind: .marker, range: NSRange(location: NSMaxRange(range) - markerLength, length: markerLength)))
                // Bold and italic may nest, so only code and links block others.
                if kind == .strike { taken.append(range) }
            }
        }
        return spans
    }
}
