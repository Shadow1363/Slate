import Foundation

/// A locked scene that's gone from the script: printed as `14  OMITTED`.
public struct OmittedScene: Sendable, Equatable {
    /// The current scene it prints before (the scene count: at the end).
    public var before: Int
    public var number: String
    public var heading: String

    public init(before: Int, number: String, heading: String) {
        self.before = before
        self.number = number
        self.heading = heading
    }
}

/// Everything production mode changes in the printed script.
public struct ProductionLayout: Sendable, Equatable {
    /// One label per scene in script order (`14`, `14A`).
    public var sceneLabels: [String]?
    public var omitted: [OmittedScene] = []
    /// Locked page starts.
    public var pages: [PageAnchor]?
    /// Script lines changed in the current revision.
    public var changed: Set<SourceRef> = []
    public var revision: ScriptRevision?

    public init(sceneLabels: [String]? = nil, omitted: [OmittedScene] = [], pages: [PageAnchor]? = nil,
                changed: Set<SourceRef> = [], revision: ScriptRevision? = nil) {
        self.sceneLabels = sceneLabels
        self.omitted = omitted
        self.pages = pages
        self.changed = changed
        self.revision = revision
    }

    /// Builds the layout for parsed act files from the production file and the
    /// current revision's baseline texts (by file name).
    public static func make(files: [(name: String, parsed: ParsedScript)], production: ProductionFile,
                            baseline: [(name: String, text: String)]?) -> ProductionLayout {
        let scenes = SceneNumbering.scenes(in: files.map(\.parsed))
        var layout = ProductionLayout()
        layout.sceneLabels = SceneNumbering.labels(scenes, locked: production.scenes)
        if let locked = production.scenes { layout.omitted = SceneNumbering.omitted(scenes, locked: locked) }
        layout.pages = production.pages
        if let revision = production.currentRevision, let baseline {
            layout.revision = revision
            layout.changed = RevisionDiff.changedLines(current: files, baseline: baseline)
        }
        return layout
    }
}

// MARK: - Scene numbers

public enum SceneNumbering {
    /// A scene's ID and Fountain number (`#14A#`), in script order.
    public struct Scene: Sendable, Equatable {
        public var id: String?
        public var fountainNumber: String?
        public var heading: String

        public init(id: String?, fountainNumber: String? = nil, heading: String = "") {
            self.id = id
            self.fountainNumber = fountainNumber
            self.heading = heading
        }
    }

    public static func scenes(in files: [ParsedScript]) -> [Scene] {
        files.flatMap { parsed in
            parsed.scenes.map { scene in
                let heading = SceneHeading.parse(parsed.lines[scene.headingLine].text)
                return Scene(id: scene.sceneID, fountainNumber: heading.attributes["number"], heading: heading.heading)
            }
        }
    }

    /// Labels in script order. Unlocked: a Fountain number if the heading has
    /// one, else its position. Locked: the locked number, and new scenes take
    /// a letter after the scene before them (`14A`, `14B`), or before the
    /// first one (`A1`).
    public static func labels(_ scenes: [Scene], locked: [LockedScene]?) -> [String] {
        guard let locked else {
            return scenes.enumerated().map { index, scene in scene.fountainNumber ?? String(index + 1) }
        }
        let numbers = Dictionary(locked.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        var used = Set(locked.map(\.number))
        var labels: [String] = []
        for (index, scene) in scenes.enumerated() {
            if let id = scene.id, let number = numbers[id] {
                labels.append(number)
                continue
            }
            var label: String
            if let previous = labels.last {
                label = lettered(after: previous)
                while used.contains(label) { label = lettered(after: label) }
            } else {
                // Before the first locked scene: A1, B1…
                let first = scenes[(index + 1)...].lazy.compactMap { $0.id.flatMap { numbers[$0] } }.first ?? "1"
                var letter: UnicodeScalar = "A"
                label = String(letter) + first
                while used.contains(label), letter.value < 90 {
                    letter = UnicodeScalar(letter.value + 1)!
                    label = String(letter) + first
                }
            }
            used.insert(label)
            labels.append(label)
        }
        return labels
    }

    /// `14` → `14A`, `14A` → `14B`, `14Z` → `14ZA`.
    static func lettered(after label: String) -> String {
        guard let last = label.unicodeScalars.last, CharacterSet.uppercaseLetters.contains(last),
              label.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return label + "A" }
        if last.value < 90 { return String(label.dropLast()) + String(UnicodeScalar(last.value + 1)!) }
        return label + "A"
    }

    /// Locked scenes no longer in the script, placed before the next locked scene that is.
    public static func omitted(_ scenes: [Scene], locked: [LockedScene]) -> [OmittedScene] {
        let present = Dictionary(scenes.enumerated().compactMap { index, scene in scene.id.map { ($0, index) } },
                                 uniquingKeysWith: { first, _ in first })
        var result: [OmittedScene] = []
        for (index, scene) in locked.enumerated() where present[scene.id] == nil {
            let before = locked[(index + 1)...].lazy.compactMap { present[$0.id] }.first ?? scenes.count
            result.append(OmittedScene(before: before, number: scene.number, heading: scene.heading))
        }
        return result
    }

    /// Locks the current numbers (keeping any already locked or given in Fountain).
    public static func lock(_ scenes: [Scene], existing: [LockedScene]?) -> [LockedScene] {
        let labels = labels(scenes, locked: existing)
        var result: [LockedScene] = []
        for (scene, label) in zip(scenes, labels) {
            guard let id = scene.id else { continue }
            result.append(LockedScene(id: id, number: label, heading: scene.heading))
        }
        // Scenes already omitted stay locked, so they keep printing as OMITTED,
        // just before the next locked scene still in the script (as they print).
        let existing = existing ?? []
        let ids = Set(result.map(\.id))
        for (index, old) in existing.enumerated() where !ids.contains(old.id) {
            let next = existing[(index + 1)...].first { ids.contains($0.id) }?.id
            let position = next.flatMap { id in result.firstIndex { $0.id == id } } ?? result.count
            result.insert(old, at: position)
        }
        return result
    }
}

// MARK: - Revision marks

public enum RevisionDiff {
    /// Lines that print (the rest never get a mark).
    static func printable(_ line: ScriptLine) -> Bool {
        switch line.kind {
        case .blank, .boneyard, .synopsis, .section, .pageBreak: false
        default: true
        }
    }

    /// Script lines changed since the baseline: added or edited lines, plus the
    /// line after anything deleted. Files are matched by name; a new file is all new.
    public static func changedLines(current: [(name: String, parsed: ParsedScript)],
                                    baseline: [(name: String, text: String)]) -> Set<SourceRef> {
        let old = Dictionary(baseline.map { ($0.name, $0.text) }, uniquingKeysWith: { first, _ in first })
        var changed: Set<SourceRef> = []
        for (fileIndex, file) in current.enumerated() {
            let newLines = file.parsed.lines.filter(printable)
            let newKeys = newLines.map(key)
            guard let oldText = old[file.name] else {
                for line in newLines { changed.insert(SourceRef(file: fileIndex, line: line.index)) }
                continue
            }
            let oldKeys = ScriptParser.parse(oldText).lines.filter(printable).map(key)
            let difference = newKeys.difference(from: oldKeys)
            var inserted: Set<Int> = [], removed: Set<Int> = []
            for change in difference {
                switch change {
                case .insert(let offset, _, _): inserted.insert(offset)
                case .remove(let offset, _, _): removed.insert(offset)
                }
            }
            for offset in inserted { changed.insert(SourceRef(file: fileIndex, line: newLines[offset].index)) }
            // A deletion marks the line that now stands where it was.
            var i = 0, j = 0
            while i < oldKeys.count || j < newKeys.count {
                if i < oldKeys.count, removed.contains(i) {
                    if !newLines.isEmpty {
                        let target = min(j, newLines.count - 1)
                        changed.insert(SourceRef(file: fileIndex, line: newLines[target].index))
                    }
                    i += 1
                } else if j < newKeys.count, inserted.contains(j) {
                    j += 1
                } else {
                    i += 1
                    j += 1
                }
            }
        }
        return changed
    }

    /// What a line prints, with its kind: scene tags and spacing don't count as changes.
    private static func key(_ line: ScriptLine) -> String {
        line.kind.rawValue + "|" + ScriptEstimate.printedText(of: line).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Locked pages

public enum PageAnchors {
    /// Records where each page of a layout starts.
    public static func make(from paginated: PaginatedScript, files: [ParsedScript]) -> [PageAnchor] {
        paginated.pages.compactMap { page in
            guard let source = page.startSource else { return nil }
            return PageAnchor(page: page.label, at: reference(for: source, files: files), row: page.startRow,
                              text: text(at: source, files: files))
        }
    }

    /// `s003 action-2`, `start`, or `@1:12` (file and line) for lines outside any scene with an ID.
    static func reference(for source: SourceRef, files: [ParsedScript]) -> String {
        if source.file == 0, source.line == 0 { return "start" }
        guard files.indices.contains(source.file) else { return "@\(source.file):\(source.line)" }
        let parsed = files[source.file]
        if let index = parsed.sceneIndex(containingLine: source.line), let id = parsed.scenes[index].sceneID,
           let element = ScriptRange.element(atLine: source.line, in: parsed.scenes[index], of: parsed) {
            return "\(id) \(element)"
        }
        return "@\(source.file):\(source.line)"
    }

    static func text(at source: SourceRef, files: [ParsedScript]) -> String {
        guard files.indices.contains(source.file), files[source.file].lines.indices.contains(source.line) else { return "" }
        return String(ScriptEstimate.printedText(of: files[source.file].lines[source.line]).prefix(40))
    }

    /// Finds an anchor's line in the current script: by its text inside its
    /// scene first (so edits above it don't move it), then by element position.
    public static func resolve(_ anchor: PageAnchor, files: [ParsedScript]) -> SourceRef? {
        if anchor.at == "start" {
            // The first line that prints.
            for (fileIndex, parsed) in files.enumerated() {
                if let line = parsed.lines.first(where: RevisionDiff.printable) { return SourceRef(file: fileIndex, line: line.index) }
            }
            return nil
        }
        if anchor.at.hasPrefix("@") {
            let parts = anchor.at.dropFirst().split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, files.indices.contains(parts[0]), files[parts[0]].lines.indices.contains(parts[1]) else { return nil }
            return SourceRef(file: parts[0], line: parts[1])
        }
        let parts = anchor.at.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let element = ScriptRange.Element(parts[1]) else { return nil }
        for (fileIndex, parsed) in files.enumerated() {
            guard let scene = parsed.scenes.first(where: { $0.sceneID == parts[0] }) else { continue }
            let elements = ScriptRange.elements(in: scene, of: parsed)
            if !anchor.text.isEmpty {
                let matches = elements.filter {
                    $0.element.kind == element.kind
                        && ScriptEstimate.printedText(of: parsed.lines[$0.line]).hasPrefix(anchor.text)
                }
                // The match nearest the recorded position.
                if let best = matches.min(by: { abs($0.element.number - element.number) < abs($1.element.number - element.number) }) {
                    return SourceRef(file: fileIndex, line: best.line)
                }
            }
            if let match = elements.first(where: { $0.element == element }) { return SourceRef(file: fileIndex, line: match.line) }
            return nil
        }
        return nil
    }
}
