import Foundation

/// The whole screenplay: every script file in `script/`, joined in name order.
public struct ScriptBook: Sendable, Equatable {
    public struct File: Sendable, Equatable, Identifiable {
        public let path: String
        public let parsed: ParsedScript
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
    }

    public struct Scene: Sendable, Equatable, Identifiable {
        public let file: String
        public let scene: ScriptScene
        /// 1-based position in the whole script.
        public let number: Int
        /// Length in eighths of a page (approximate until Milestone 3's page engine).
        public let eighths: Int
        /// `dur=` override, or one minute per page.
        public let duration: TimeInterval

        public var id: String { "\(file)#\(scene.headingLine)" }
    }

    public let files: [File]
    public let scenes: [Scene]
    /// Cue names, most-used first.
    public let characters: [String]
    /// Locations from headings, most-used first: `KITCHEN`, `ROOF`.
    public let locations: [String]
    /// Times of day from headings, most-used first: `NIGHT`, `DAY`.
    public let times: [String]
    public let totalLines: Int
    public let wordCount: Int

    public var sceneIDs: Set<String> { Set(scenes.compactMap(\.scene.sceneID)) }
    public var totalEighths: Int { scenes.reduce(0) { $0 + $1.eighths } }
    public var totalDuration: TimeInterval { scenes.reduce(0) { $0 + $1.duration } }
    /// Approximate pages, from `ScriptEstimate.linesPerPage`.
    public var pageCount: Double { Double(totalLines) / Double(ScriptEstimate.linesPerPage) }

    public init(texts: [(path: String, text: String)]) {
        self.init(parsed: texts.map { ($0.path, ScriptParser.parse($0.text)) })
    }

    public init(parsed: [(path: String, parsed: ParsedScript)]) {
        files = parsed.map { File(path: $0.path, parsed: $0.parsed) }
        var scenes: [Scene] = []
        var characterCounts: [String: Int] = [:]
        var locationCounts: [String: Int] = [:]
        var timeCounts: [String: Int] = [:]
        var totalLines = 0
        var words = 0
        for file in files {
            for line in file.parsed.lines {
                totalLines += ScriptEstimate.lines(for: line)
                words += ScriptEstimate.words(in: line)
            }
            for cue in file.parsed.characterCues { characterCounts[cue, default: 0] += 1 }
            for scene in file.parsed.scenes {
                let parts = SceneHeading.parse(file.parsed.lines[scene.headingLine].text).parts
                if !parts.location.isEmpty { locationCounts[parts.location.uppercased(), default: 0] += 1 }
                if let time = parts.time { timeCounts[time.uppercased(), default: 0] += 1 }
                let lines = scene.lines.reduce(0) { $0 + ScriptEstimate.lines(for: file.parsed.lines[$1]) }
                let eighths = ScriptEstimate.eighths(forLines: lines)
                scenes.append(Scene(
                    file: file.path,
                    scene: scene,
                    number: scenes.count + 1,
                    eighths: eighths,
                    duration: scene.durationOverride ?? Double(eighths) / 8 * 60
                ))
            }
        }
        self.scenes = scenes
        self.totalLines = totalLines
        self.wordCount = words
        func ranked(_ counts: [String: Int]) -> [String] {
            counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        }
        characters = ranked(characterCounts)
        locations = ranked(locationCounts)
        times = ranked(timeCounts)
    }

    /// The next free ID: one more than the highest `sNNN`, zero-padded to 3 digits.
    public static func nextSceneID(existing: Set<String>) -> String {
        let highest = existing.compactMap { id -> Int? in
            guard id.hasPrefix("s") else { return nil }
            return Int(id.dropFirst())
        }.max() ?? 0
        return String(format: "s%03d", highest + 1)
    }

    /// The script files in `script/`, in the order they join: Markdown,
    /// Fountain or text files directly in the folder, except the title page.
    public static func scriptFiles(in files: [ProjectFile]) -> [ProjectFile] {
        files
            .filter { file in
                file.area == .script
                    && !file.pathInArea.contains("/")
                    && file.name != "title-page.md"
                    && ["md", "fountain", "txt"].contains((file.name as NSString).pathExtension.lowercased())
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Rough page maths until Milestone 3's pagination engine: Courier at
/// 10 characters per inch, 55 lines per page, element widths from SPEC.md.
public enum ScriptEstimate {
    public static let linesPerPage = 55

    /// Printed lines a script line takes, after wrapping.
    public static func lines(for line: ScriptLine) -> Int {
        let width: Int
        switch line.kind {
        case .boneyard, .synopsis, .pageBreak: return 0
        case .blank, .character: return 1
        case .dialogue, .lyric: width = 35
        case .parenthetical: width = 20
        case .sceneHeading, .action, .transition, .centered: width = 60
        }
        let length = printedText(of: line).count
        return max(1, Int((Double(length) / Double(width)).rounded(.up)))
    }

    public static func words(in line: ScriptLine) -> Int {
        switch line.kind {
        case .boneyard, .synopsis, .pageBreak, .blank: return 0
        default: return printedText(of: line).split(whereSeparator: \.isWhitespace).count
        }
    }

    /// The line as it prints: no marker, no scene tag.
    public static func printedText(of line: ScriptLine) -> String {
        var ns = line.text as NSString
        if let tag = line.tagRange {
            ns = ns.replacingCharacters(in: NSRange(location: tag.location - line.range.location, length: tag.length), with: "") as NSString
        }
        return ns.substring(from: min(line.markerLength, ns.length)).trimmingCharacters(in: .whitespaces)
    }

    /// At least one eighth for any scene.
    public static func eighths(forLines lines: Int) -> Int {
        max(1, Int((Double(lines) / Double(linesPerPage) * 8).rounded()))
    }

    /// `1 3/8`, `7/8`, `2`.
    public static func formatEighths(_ eighths: Int) -> String {
        let pages = eighths / 8
        let rest = eighths % 8
        switch (pages, rest) {
        case (_, 0): return "\(pages)"
        case (0, _): return "\(rest)/8"
        default: return "\(pages) \(rest)/8"
        }
    }

    /// `2:30`, `1:02:00`.
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
