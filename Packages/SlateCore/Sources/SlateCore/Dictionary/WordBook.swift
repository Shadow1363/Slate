import Foundation

/// One entry in a word book (`dictionary/words.md`).
///
/// ```markdown
/// - **Chronoshift** *noun* (chronoshifts, chronoshifted) — A jump between loops that keeps memory.
///   Longer explanations continue on indented lines.
/// - **Rhodium-9** — [[Rhodium-9]]
/// - Riley
/// ```
public struct WordEntry: Sendable, Equatable, Identifiable {
    public var word: String
    /// Part of speech, from `*noun*` after the word.
    public var part: String?
    /// Other accepted forms, from `(a, b)` after the word.
    public var forms: [String]
    /// What it means, as Markdown; empty for a spelling-only entry.
    public var explanation: String
    /// 0-based lines the entry spans in its file (empty for a new entry).
    public let lines: Range<Int>
    /// The lines as read, to check nothing moved before editing them.
    public let source: String

    public init(word: String, part: String? = nil, forms: [String] = [], explanation: String = "", lines: Range<Int> = 0..<0, source: String = "") {
        self.word = word
        self.part = part
        self.forms = forms
        self.explanation = explanation
        self.lines = lines
        self.source = source
    }

    public var id: String { "\(lines.lowerBound):\(word)" }

    /// The word and every form.
    public var allForms: [String] { [word] + forms }

    /// Just a correct spelling: nothing to define or link.
    public var isSpellingOnly: Bool {
        explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && part == nil
    }

    public var links: [WikiLink] { WikiLink.find(in: explanation) }

    /// The explanation is nothing but a link (optionally "See [[X]]."),
    /// so the note it points to is the definition.
    public var linkedNoteOnly: String? {
        let links = links
        guard links.count == 1 else { return nil }
        let ns = explanation as NSString
        var rest = ns.replacingCharacters(in: links[0].range, with: "")
        rest = rest.replacingOccurrences(of: "see", with: "", options: [.caseInsensitive])
        let leftover = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return leftover.isEmpty ? links[0].target : nil
    }

    /// The explanation as plain text (links shown by their text, emphasis kept as written).
    public var plainExplanation: String {
        var text = explanation
        for link in links.reversed() {
            text = (text as NSString).replacingCharacters(in: link.range, with: link.displayText)
        }
        return text
    }

    /// The entry written as list lines.
    public var markdownLines: [String] {
        let explanation = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = word.trimmingCharacters(in: .whitespaces)
        if explanation.isEmpty, part == nil, forms.isEmpty { return ["- " + word] }
        var head = "- **\(word)**"
        if let part, !part.isEmpty { head += " *\(part)*" }
        let forms = forms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !forms.isEmpty { head += " (" + forms.joined(separator: ", ") + ")" }
        guard !explanation.isEmpty else { return [head] }
        let parts = explanation.components(separatedBy: "\n")
        return [head + " — " + parts[0]] + parts.dropFirst().map { $0.isEmpty ? "" : "  " + $0 }
    }
}

/// Reads and edits a word book: the project's `dictionary/words.md` or the
/// global one in Application Support. Edits touch only an entry's own lines
/// (plus a letter heading when one is missing), so the rest of the file
/// stays as written.
public enum WordBook {
    public static let path = "dictionary/words.md"
    public static let starter = "# Dictionary\n\n"

    // MARK: - Reading

    public static func parse(_ text: String) -> [WordEntry] {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var entries: [WordEntry] = []
        var index = 0
        var inFence = false
        var inComment = false
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inComment {
                if trimmed.contains("-->") { inComment = false }
                index += 1
                continue
            }
            if trimmed.hasPrefix("<!--") {
                if !trimmed.contains("-->") { inComment = true }
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if inFence || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                index += 1
                continue
            }
            let body: String
            if let match = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
                body = String(match.1)
            } else if isBareWord(line) {
                body = trimmed
            } else {
                index += 1
                continue
            }
            var continuation: [String] = []
            var end = index + 1
            while end < lines.count, let first = lines[end].first, first == " " || first == "\t",
                  !lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                continuation.append(lines[end].trimmingCharacters(in: .whitespaces))
                end += 1
            }
            if var entry = parseBody(body) {
                if !continuation.isEmpty {
                    entry.explanation = ([entry.explanation].filter { !$0.isEmpty } + continuation).joined(separator: "\n")
                }
                entries.append(WordEntry(
                    word: entry.word, part: entry.part, forms: entry.forms, explanation: entry.explanation,
                    lines: index..<end, source: lines[index..<end].joined(separator: "\n")
                ))
            }
            index = end
        }
        return entries
    }

    /// A pasted word list: a short line that isn't Markdown structure or prose.
    static func isBareWord(_ line: String) -> Bool {
        guard let first = line.first, first != " ", first != "\t" else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !"#>|".contains(trimmed.first!) else { return false }
        guard !trimmed.contains("—"), !trimmed.contains(" - "), !trimmed.contains(": ") else { return false }
        guard let last = trimmed.last, !".,;!?".contains(last) else { return false }
        return trimmed.split(separator: " ").count <= 3
    }

    /// `**Word** *part* (forms) — explanation`, every piece but the word optional.
    static func parseBody(_ raw: String) -> WordEntry? {
        var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return nil }
        // A task-list box isn't part of the word.
        if let box = rest.firstMatch(of: /^\[[ xX]\]\s+/) { rest = rest[box.range.upperBound...] }

        var word: String
        if let bold = rest.firstMatch(of: /^(?:\*\*|__)(.+?)(?:\*\*|__)/) {
            word = String(bold.1)
            rest = rest[bold.range.upperBound...]
        } else {
            // Up to the part of speech, the forms or the separator.
            let stop = rest.firstRange(of: /\s+\*|\s*\(|\s*[—–]|\s+-\s|:\s|:$/)?.lowerBound ?? rest.endIndex
            word = String(rest[..<stop])
            rest = rest[stop...]
        }
        word = word.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return nil }

        rest = rest.drop { $0 == " " || $0 == "\t" }
        var part: String?
        if let match = rest.firstMatch(of: /^[*_]([^*_]+)[*_]/) {
            part = String(match.1).trimmingCharacters(in: .whitespaces)
            rest = rest[match.range.upperBound...].drop { $0 == " " || $0 == "\t" }
        }
        var forms: [String] = []
        if let match = rest.firstMatch(of: /^\(([^)]*)\)/) {
            forms = match.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            rest = rest[match.range.upperBound...].drop { $0 == " " || $0 == "\t" }
        }
        var explanation = ""
        if let match = rest.firstMatch(of: /^(?:—|–|-{1,2}|:)\s*(.*)$/) {
            explanation = String(match.1)
        } else if !rest.isEmpty {
            // Something after the word without a separator: keep it as the explanation.
            explanation = String(rest)
        }
        return WordEntry(word: word, part: part?.isEmpty == true ? nil : part, forms: forms,
                         explanation: explanation.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Editing

    /// The letter an entry is filed under: A–Z, or `#` for anything else.
    public static func letter(for word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        guard let first = folded.first, first.isASCII, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    static func letterHeading(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^##\s+(\S)\s*$/) else { return nil }
        let letter = String(match.1).uppercased()
        return letter == "#" || (letter.first!.isASCII && letter.first!.isLetter) ? letter : nil
    }

    /// Letters sort A–Z with `#` last.
    static func letterRank(_ letter: String) -> Int {
        letter == "#" ? 27 : Int(letter.unicodeScalars.first!.value) - 64
    }

    static func compareWords(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .numeric]) == .orderedAscending
    }

    /// Files a new entry alphabetically under its `## Letter` heading,
    /// adding the heading (in order) if it's missing.
    public static func adding(_ entry: WordEntry, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines = ["# Dictionary"]
        }
        let item = entry.markdownLines
        let letter = letter(for: entry.word)
        let existing = parse(lines.joined(separator: "\n"))

        if let heading = lines.firstIndex(where: { letterHeading($0) == letter }) {
            var end = heading + 1
            while end < lines.count, !lines[end].hasPrefix("#") { end += 1 }
            let section = existing.filter { $0.lines.lowerBound > heading && $0.lines.lowerBound < end }
            if let next = section.first(where: { compareWords(entry.word, $0.word) }) {
                lines.insert(contentsOf: item, at: next.lines.lowerBound)
            } else if let last = section.last {
                lines.insert(contentsOf: item, at: last.lines.upperBound)
            } else {
                // An empty section: right under the heading, after one blank line.
                var insert = heading + 1
                var block = item
                if insert < lines.count, lines[insert].trimmingCharacters(in: .whitespaces).isEmpty {
                    insert += 1
                } else {
                    block = [""] + block
                }
                if insert < lines.count, !lines[insert].trimmingCharacters(in: .whitespaces).isEmpty { block += [""] }
                lines.insert(contentsOf: block, at: insert)
            }
        } else {
            let block = ["## \(letter)", ""] + item
            let later = lines.firstIndex { line in
                letterHeading(line).map { letterRank($0) > letterRank(letter) } ?? false
            }
            if let later {
                lines.insert(contentsOf: block + [""], at: later)
            } else {
                while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
                if !lines.isEmpty { lines.append("") }
                lines += block
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Replaces an entry. Returns nil if its lines changed since they were read.
    public static func replacing(_ entry: WordEntry, with updated: WordEntry, in text: String) -> String? {
        guard verify(entry, text) else { return nil }
        if letter(for: entry.word) != letter(for: updated.word) {
            guard let removed = removing(entry, in: text) else { return nil }
            return adding(updated, to: removed)
        }
        var lines = text.components(separatedBy: "\n")
        lines.replaceSubrange(entry.lines, with: updated.markdownLines)
        return lines.joined(separator: "\n")
    }

    /// Removes an entry. Returns nil if its lines changed since they were read.
    public static func removing(_ entry: WordEntry, in text: String) -> String? {
        guard verify(entry, text) else { return nil }
        var lines = text.components(separatedBy: "\n")
        lines.removeSubrange(entry.lines)
        return lines.joined(separator: "\n")
    }

    static func verify(_ entry: WordEntry, _ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard entry.lines.upperBound <= lines.count, !entry.lines.isEmpty else { return false }
        return lines[entry.lines].joined(separator: "\n") == entry.source
    }

    /// The entry for a word or one of its forms, ignoring case and accents.
    public static func entry(for word: String, in entries: [WordEntry]) -> WordEntry? {
        let key = fold(word)
        let defined = entries.filter { !$0.isSpellingOnly }
        return defined.first { $0.allForms.contains { fold($0) == key } }
            ?? entries.first { $0.allForms.contains { fold($0) == key } }
    }

    // MARK: - Search

    /// Entries matching `query` in the word, a form or the explanation;
    /// words starting with the query first.
    public static func search(_ query: String, in entries: [WordEntry]) -> [WordEntry] {
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return sorted(entries) }
        let scored: [(Int, WordEntry)] = entries.compactMap { entry in
            let word = fold(entry.word)
            let forms = entry.forms.map(fold)
            if word == needle { return (0, entry) }
            if word.hasPrefix(needle) { return (1, entry) }
            if forms.contains(where: { $0.hasPrefix(needle) }) { return (2, entry) }
            if word.contains(needle) || forms.contains(where: { $0.contains(needle) }) { return (3, entry) }
            if fold(entry.explanation).contains(needle) || fold(entry.part ?? "") == needle { return (4, entry) }
            return nil
        }
        return scored.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : compareWords(a.1.word, b.1.word) }.map(\.1)
    }

    /// A–Z (then `#`), ignoring case and accents.
    public static func sorted(_ entries: [WordEntry]) -> [WordEntry] {
        entries.sorted { a, b in
            let la = letterRank(letter(for: a.word)), lb = letterRank(letter(for: b.word))
            return la != lb ? la < lb : compareWords(a.word, b.word)
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
