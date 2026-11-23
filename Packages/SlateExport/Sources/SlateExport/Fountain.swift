import Foundation
import SlateCore

/// A screenplay converted into Slate's files, ready to write into a project.
public struct ImportedScript: Sendable, Equatable {
    /// Contents of `script/title-page.md` (empty if the source had none).
    public var titlePage: String
    /// Act files in order: (file name in `script/`, contents).
    public var files: [File]

    public struct File: Sendable, Equatable {
        public var name: String
        public var text: String
    }

    /// Writes the files into an existing project's `script/` folder,
    /// replacing the template's starter script files.
    public func write(into projectRoot: URL) throws {
        let script = projectRoot.appending(path: ProjectLayout.script, directoryHint: .isDirectory)
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: script.path)) ?? []
        where name != "title-page.md" && ["md", "fountain", "txt"].contains((name as NSString).pathExtension) {
            let url = script.appending(path: name)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // Only template starters (empty, or a lone act section or label) are replaced.
            let content = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty || (!content.contains("\n") && (content.hasPrefix("#") || content.hasPrefix("/*"))) {
                try fm.removeItem(at: url)
            }
        }
        if !titlePage.isEmpty {
            try CoordinatedFileIO.writeText(titlePage, to: script.appending(path: "title-page.md"))
        }
        for file in files {
            try CoordinatedFileIO.writeText(file.text, to: script.appending(path: file.name))
        }
    }
}

/// Fountain (`.fountain`, or a plain `.txt`/`.md` screenplay) → Slate.
///
/// - The title page becomes `title-page.md`.
/// - Top-level `# Sections` start numbered act files (`01-act-one.md`) and
///   stay as the first line of that file; deeper sections stay where they are.
/// - Headings, forced (`.HEADING`) or not, stay as written.
/// - Fountain `[[notes]]` become `/* note: … */`, since Slate uses `[[…]]` for links.
/// - Every scene heading gets a Slate scene ID.
public enum FountainImporter {
    public static func convert(_ source: String, fallbackName: String = "script.md") -> ImportedScript {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var lines = text.components(separatedBy: "\n")

        let titleLines = takeTitlePage(&lines)
        let titlePage = titleLines.isEmpty ? "" : TitlePage.parse(titleLines.joined(separator: "\n")).text

        var acts: [(title: String?, lines: [String])] = [(nil, [])]
        var inBoneyard = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBoneyard {
                acts[acts.count - 1].lines.append(line)
                if line.contains("*/") { inBoneyard = false }
                continue
            }
            if trimmed.hasPrefix("/*"), !trimmed.contains("*/") {
                inBoneyard = true
                acts[acts.count - 1].lines.append(line)
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let title = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level == 1 {
                    acts.append((title, [trimmed]))
                } else {
                    acts[acts.count - 1].lines.append(line)
                }
                continue
            }
            var converted = line
            if converted.contains("[[") {
                converted = converted.replacingOccurrences(of: #"\[\[(.*?)\]\]"#, with: "/* note: $1 */", options: .regularExpression)
            }
            acts[acts.count - 1].lines.append(converted)
        }

        // Text before the first section joins the first act.
        if acts.count > 1 {
            let lead = acts.removeFirst().lines
            if lead.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                acts[0].lines = lead + acts[0].lines
            }
        }

        var files: [ImportedScript.File] = []
        var usedIDs: Set<String> = []
        for (index, act) in acts.enumerated() {
            var body = act.lines
            while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
            while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
            // One blank line between the act's section and what follows.
            if act.title != nil, body.count > 1 {
                while body.count > 1, body[1].trimmingCharacters(in: .whitespaces).isEmpty { body.remove(at: 1) }
                body.insert("", at: 1)
            }
            let tagged = ScriptEditing.assigningSceneIDs(to: body.joined(separator: "\n") + "\n", existing: usedIDs)
            usedIDs.formUnion(ScriptParser.parse(tagged).scenes.compactMap(\.sceneID))
            let name: String
            if let title = act.title {
                name = String(format: "%02d-%@.md", index + 1, slug(title))
            } else {
                name = fallbackName
            }
            files.append(.init(name: name, text: tagged))
        }
        return ImportedScript(titlePage: titlePage, files: files)
    }

    /// Removes and returns the title page: `Key: value` lines at the very
    /// start, up to the first blank line.
    private static func takeTitlePage(_ lines: inout [String]) -> [String] {
        var start = 0
        while start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).isEmpty { start += 1 }
        guard start < lines.count, let colon = lines[start].firstIndex(of: ":"),
              lines[start][..<colon].allSatisfy({ $0.isLetter || $0 == " " }),
              !lines[start][..<colon].isEmpty,
              !ScriptParser.isHeading(lines[start])
        else { return [] }
        var end = start
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
        let title = Array(lines[start..<end])
        lines.removeSubrange(0..<end)
        return title
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "act" : String(collapsed.prefix(40))
    }
}

/// Slate → one `.fountain` file other apps can open.
public enum FountainExporter {
    /// - Parameters:
    ///   - titlePage: Contents of `title-page.md`.
    ///   - files: Act files in order: (file name, text).
    /// - Parameter sceneLabels: Locked scene numbers, written as Fountain's `#14A#`.
    public static func export(titlePage: String, files: [(name: String, text: String)], sceneLabels: [String]? = nil) -> String {
        var output: [String] = []
        var sceneIndex = 0
        let title = TitlePage.parse(titlePage)
        if !title.isEmpty {
            output.append(title.text.trimmingCharacters(in: .newlines))
            output.append("")
        }
        for (index, file) in files.enumerated() {
            let parsed = ScriptParser.parse(file.text)
            let opensWithAct = parsed.lines.first { $0.kind != .blank }.map { $0.kind == .section && !$0.text.hasPrefix("##") } ?? false
            if index > 0 { output.append("") }
            if files.count > 1, !opensWithAct {
                output.append("# " + sectionTitle(for: file.name))
                output.append("")
            }
            for line in parsed.lines {
                var text = fountainLine(line)
                if line.kind == .sceneHeading {
                    if let labels = sceneLabels, labels.indices.contains(sceneIndex) {
                        let range = NSRange(location: 0, length: (text as NSString).length)
                        text = SceneHeading.numberPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
                        text += " #\(labels[sceneIndex])#"
                    }
                    sceneIndex += 1
                }
                output.append(text)
            }
            while output.last == "" { output.removeLast() }
        }
        return output.joined(separator: "\n") + "\n"
    }

    static func fountainLine(_ line: ScriptLine) -> String {
        switch line.kind {
        case .sceneHeading:
            let heading = ScriptEstimate.printedText(of: line)
            return ScriptParser.isHeading(heading) ? heading : "." + heading
        case .boneyard, .section:
            return line.text
        default:
            return Emphasis.printable(line.text, keepingComments: true)
        }
    }

    /// `02-act-two.md` → `Act Two`.
    static func sectionTitle(for fileName: String) -> String {
        var base = (fileName as NSString).deletingPathExtension
        if let dash = base.firstIndex(of: "-"), base[..<dash].allSatisfy(\.isNumber) {
            base = String(base[base.index(after: dash)...])
        }
        return base.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Slate → plain Markdown: the joined script with scene tags and markers removed.
public enum MarkdownExporter {
    public static func export(titlePage: String, files: [(name: String, text: String)]) -> String {
        var output: [String] = []
        if let title = TitlePage.parse(titlePage).title {
            output.append("# " + title)
            output.append("")
        }
        for file in files {
            for line in ScriptParser.parse(file.text).lines {
                switch line.kind {
                case .sceneHeading:
                    output.append("## " + ScriptEstimate.printedText(of: line))
                case .boneyard, .synopsis, .section:
                    continue
                case .character:
                    output.append("**" + ScriptEstimate.printedText(of: line) + "**  ")
                case .parenthetical, .dialogue:
                    output.append(Emphasis.printable(ScriptEstimate.printedText(of: line)) + "  ")
                default:
                    output.append(Emphasis.printable(ScriptEstimate.printedText(of: line)))
                }
            }
            output.append("")
        }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }
}
