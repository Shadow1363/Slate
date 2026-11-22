import Foundation
import Markdown

/// The block structure of a Markdown body, from swift-markdown: headings for
/// the outline, and code blocks so links inside them are ignored.
public struct MarkdownOutline: Sendable, Equatable {
    public struct Heading: Sendable, Equatable, Identifiable, Codable {
        public let level: Int
        public let title: String
        /// 0-based line in the text that was parsed.
        public let line: Int
        /// UTF-16 range of the whole heading line.
        public let range: NSRange
        public var id: Int { line }
    }

    public let headings: [Heading]
    /// UTF-16 ranges that are code: fenced and indented blocks, HTML blocks
    /// and inline code spans.
    public let codeRanges: [NSRange]

    public static let empty = MarkdownOutline(headings: [], codeRanges: [])

    public init(headings: [Heading], codeRanges: [NSRange]) {
        self.headings = headings
        self.codeRanges = codeRanges
    }

    /// Parses `text`. `offset` is added to every range, so a body parsed on
    /// its own can report ranges in the whole note.
    public init(parsing text: String, offset: Int = 0) {
        let lines = LineTable(text)
        let document = Document(parsing: text)
        var walker = Walker()
        walker.visit(document)

        var headings: [Heading] = []
        for (level, title, line) in walker.headings where lines.contains(line) {
            let range = lines.range(ofLine: line)
            headings.append(Heading(level: level, title: title, line: line, range: NSRange(location: range.location + offset, length: range.length)))
        }

        var code: [NSRange] = []
        var codeLines = IndexSet()
        for block in walker.codeBlocks {
            let first = max(block.lowerBound, 0)
            let last = min(block.upperBound, lines.count - 1)
            guard first <= last else { continue }
            codeLines.insert(integersIn: first...last)
            let start = lines.range(ofLine: first).location
            let end = NSMaxRange(lines.range(ofLine: last))
            code.append(NSRange(location: start + offset, length: end - start))
        }
        for line in 0..<lines.count where !codeLines.contains(line) {
            let range = lines.range(ofLine: line)
            for span in Self.inlineCodeSpans(in: lines.text(ofLine: line)) {
                code.append(NSRange(location: range.location + span.location + offset, length: span.length))
            }
        }
        self.headings = headings
        self.codeRanges = code.sorted { $0.location < $1.location }
    }

    public func isCode(_ range: NSRange) -> Bool {
        codeRanges.contains { NSIntersectionRange($0, range).length > 0 || ($0.location <= range.location && NSMaxRange(range) <= NSMaxRange($0)) }
    }

    /// Backtick code spans on one line (UTF-16 ranges within the line).
    static func inlineCodeSpans(in line: String) -> [NSRange] {
        let units = Array(line.utf16)
        var spans: [NSRange] = []
        var i = 0
        let tick = UInt16(UInt8(ascii: "`"))
        while i < units.count {
            guard units[i] == tick else { i += 1; continue }
            var run = 0
            while i + run < units.count, units[i + run] == tick { run += 1 }
            var j = i + run
            var closed = false
            while j < units.count {
                if units[j] == tick {
                    var other = 0
                    while j + other < units.count, units[j + other] == tick { other += 1 }
                    if other == run {
                        spans.append(NSRange(location: i, length: j + other - i))
                        i = j + other
                        closed = true
                        break
                    }
                    j += other
                } else {
                    j += 1
                }
            }
            if !closed { i += run }
        }
        return spans
    }

    private struct Walker: MarkupWalker {
        var headings: [(Int, String, Int)] = []
        /// 0-based inclusive line ranges.
        var codeBlocks: [ClosedRange<Int>] = []

        mutating func visitHeading(_ heading: Markdown.Heading) {
            if let range = heading.range {
                headings.append((heading.level, heading.plainText.trimmingCharacters(in: .whitespaces), range.lowerBound.line - 1))
            }
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            if let range = codeBlock.range {
                codeBlocks.append((range.lowerBound.line - 1)...max(range.upperBound.line - 1, range.lowerBound.line - 1))
            }
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            if let range = html.range {
                codeBlocks.append((range.lowerBound.line - 1)...max(range.upperBound.line - 1, range.lowerBound.line - 1))
            }
        }

    }
}

/// UTF-16 line starts for mapping line numbers to ranges.
struct LineTable {
    private let ns: NSString
    private var starts: [Int] = [0]

    init(_ text: String) {
        ns = text as NSString
        let newline = UInt16(UInt8(ascii: "\n"))
        for (index, unit) in text.utf16.enumerated() where unit == newline {
            starts.append(index + 1)
        }
    }

    var count: Int { starts.count }

    func contains(_ line: Int) -> Bool { line >= 0 && line < starts.count }

    /// The line without its newline.
    func range(ofLine line: Int) -> NSRange {
        let start = starts[line]
        var end = line + 1 < starts.count ? starts[line + 1] - 1 : ns.length
        if end > start, ns.character(at: end - 1) == 13 { end -= 1 }
        return NSRange(location: start, length: max(end - start, 0))
    }

    func text(ofLine line: Int) -> String {
        ns.substring(with: range(ofLine: line))
    }

    /// The 0-based line holding a UTF-16 offset.
    func line(containing location: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
