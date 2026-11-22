import Foundation

/// A run of printed text with one style.
public struct PrintedRun: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false

    public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }

    var sameStyle: (Bool, Bool, Bool) { (bold, italic, underline) }
}

/// Fountain emphasis: `*italic*`, `**bold**`, `***bold italic***`,
/// `_underline_`, and `\` to escape a marker. Markers only pair within one
/// line; an unpaired marker prints as itself.
public enum Emphasis {
    public static func runs(in text: String, enabled: Bool = true) -> [PrintedRun] {
        guard enabled else { return [PrintedRun(text)] }

        enum Token { case text(String), marker(String) }
        var tokens: [Token] = []
        var buffer = ""
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "*_\\".contains(chars[i + 1]) {
                buffer.append(chars[i + 1])
                i += 2
            } else if c == "*" {
                var n = 0
                while i + n < chars.count, chars[i + n] == "*", n < 3 { n += 1 }
                if !buffer.isEmpty { tokens.append(.text(buffer)); buffer = "" }
                tokens.append(.marker(String(repeating: "*", count: n)))
                i += n
            } else if c == "_" {
                if !buffer.isEmpty { tokens.append(.text(buffer)); buffer = "" }
                tokens.append(.marker("_"))
                i += 1
            } else {
                buffer.append(c)
                i += 1
            }
        }
        if !buffer.isEmpty { tokens.append(.text(buffer)) }
        chars = []

        // A marker toggles only if it has a partner; otherwise it's literal.
        var isToggle = Array(repeating: false, count: tokens.count)
        var open: [String: Int] = [:]
        for (index, token) in tokens.enumerated() {
            guard case .marker(let m) = token else { continue }
            if let start = open[m] {
                isToggle[start] = true
                isToggle[index] = true
                open[m] = nil
            } else {
                open[m] = index
            }
        }

        var runs: [PrintedRun] = []
        var bold = false, italic = false, underline = false
        func append(_ s: String) {
            if var last = runs.last, last.sameStyle == (bold, italic, underline) {
                last.text += s
                runs[runs.count - 1] = last
            } else {
                runs.append(PrintedRun(s, bold: bold, italic: italic, underline: underline))
            }
        }
        for (index, token) in tokens.enumerated() {
            switch token {
            case .text(let s):
                append(s)
            case .marker(let m):
                guard isToggle[index] else { append(m); continue }
                switch m {
                case "*": italic.toggle()
                case "**": bold.toggle()
                case "***": bold.toggle(); italic.toggle()
                default: underline.toggle()
                }
            }
        }
        return runs.isEmpty ? [PrintedRun("")] : runs
    }

    /// Removes Slate-only markup before printing: `[[Name|shown]]` → `shown`,
    /// `[[Name]]` → `Name`, inline `/* … */` comments dropped.
    public static func printable(_ text: String, keepingComments: Bool = false) -> String {
        var result = text
        if !keepingComments, result.contains("/*") {
            result = result.replacingOccurrences(of: #"/\*.*?\*/"#, with: "", options: .regularExpression)
        }
        if result.contains("[[") {
            let ns = result as NSString
            var output = ""
            var last = 0
            for match in ScriptSpelling.linkPattern.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let inner = ns.substring(with: NSRange(location: match.range.location + 2, length: match.range.length - 4))
                output += inner.split(separator: "|", maxSplits: 1).last.map(String.init) ?? inner
                last = match.range.upperBound
            }
            output += ns.substring(from: last)
            result = output
        }
        return result
    }
}

/// Splits styled text into lines of at most `width` characters, breaking at
/// spaces. Spaces at a break are dropped; a lone `--` may hang one past the
/// edge, as screenwriting apps do; a word longer than the line is cut.
public enum LineWrapper {
    public static func wrap(_ runs: [PrintedRun], width: Int) -> [[PrintedRun]] {
        // Flatten to styled characters.
        var chars: [(Character, PrintedRun)] = []
        for run in runs {
            for c in run.text { chars.append((c, PrintedRun("", bold: run.bold, italic: run.italic, underline: run.underline))) }
        }
        let plain = chars.map(\.0)
        let ranges = wrapRanges(plain, width: width)
        return ranges.map { range in
            var line: [PrintedRun] = []
            for index in range {
                let (c, style) = chars[index]
                if var last = line.last, last.sameStyle == style.sameStyle {
                    last.text.append(c)
                    line[line.count - 1] = last
                } else {
                    var run = style
                    run.text = String(c)
                    line.append(run)
                }
            }
            return line.isEmpty ? [PrintedRun("")] : line
        }
    }

    public static func wrap(_ text: String, width: Int) -> [String] {
        let chars = Array(text)
        return wrapRanges(chars, width: width).map { String(chars[$0]) }
    }

    static func wrapRanges(_ chars: [Character], width: Int) -> [Range<Int>] {
        guard chars.count > width, width > 0 else { return [0..<chars.count] }
        var lines: [Range<Int>] = []
        var start = 0
        // Skip leading spaces only on continuation lines.
        while start < chars.count {
            if chars.count - start <= width {
                lines.append(start..<chars.count)
                break
            }
            // Last space at or before the edge.
            var breakAt: Int?
            var i = start + width
            while i > start {
                if chars[i] == " " { breakAt = i; break }
                i -= 1
            }
            // A `--` that would start the next line hangs one past the edge instead.
            if let b = breakAt, b + 2 < chars.count, chars[b + 1] == "-", chars[b + 2] == "-",
               b + 3 == chars.count || chars[b + 3] == " ", b + 3 <= start + width + 1 {
                let end = b + 3
                lines.append(start..<end)
                start = end
                while start < chars.count, chars[start] == " " { start += 1 }
                continue
            }
            guard let b = breakAt else {
                lines.append(start..<(start + width))
                start += width
                continue
            }
            var end = b
            while end > start, chars[end - 1] == " " { end -= 1 }
            lines.append(start..<end)
            start = b
            while start < chars.count, chars[start] == " " { start += 1 }
        }
        return lines
    }
}
