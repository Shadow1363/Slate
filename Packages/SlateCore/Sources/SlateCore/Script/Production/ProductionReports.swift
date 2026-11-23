import Foundation

/// The reports a production asks for, as plain rows: a scene list, a
/// character report and a location report.
public enum ProductionReport: String, Sendable, CaseIterable, Identifiable {
    case scenes, characters, locations

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .scenes: "Scene List"
        case .characters: "Character Report"
        case .locations: "Location Report"
        }
    }

    public var columns: [String] {
        switch self {
        case .scenes: ["Scene", "Int/Ext", "Location", "Time", "Pages", "Page", "Cast"]
        case .characters: ["Character", "Scenes", "Speeches", "Words", "First Page", "Scene Numbers"]
        case .locations: ["Location", "Int/Ext", "Scenes", "Pages", "Scene Numbers"]
        }
    }

    /// The report's rows (without the header). Omitted scenes are listed in the scene list.
    public func rows(files: [ParsedScript], paginated: PaginatedScript, labels: [String], omitted: [OmittedScene] = []) -> [[String]] {
        let scenes = ProductionReports.scenes(files: files, paginated: paginated, labels: labels)
        switch self {
        case .scenes:
            var rows: [[String]] = []
            for scene in scenes {
                for cut in omitted where cut.before == scene.index { rows.append([cut.number, "", "OMITTED", "", "", "", ""]) }
                rows.append([scene.number, scene.setting, scene.location, scene.time, ScriptEstimate.formatEighths(scene.eighths), scene.page,
                             scene.cast.joined(separator: ", ")])
            }
            for cut in omitted where cut.before >= scenes.count { rows.append([cut.number, "", "OMITTED", "", "", "", ""]) }
            return rows
        case .characters:
            return ProductionReports.characters(scenes).map {
                [$0.name, String($0.scenes.count), String($0.speeches), String($0.words), $0.firstPage, $0.scenes.joined(separator: ", ")]
            }
        case .locations:
            return ProductionReports.locations(scenes).map {
                [$0.location, $0.settings.joined(separator: "/"), String($0.scenes.count), ScriptEstimate.formatEighths($0.eighths),
                 $0.scenes.joined(separator: ", ")]
            }
        }
    }
}

public enum ProductionReports {
    public struct SceneRow: Sendable, Equatable {
        public var index: Int
        public var number: String
        public var id: String?
        public var heading: String
        /// `INT`, `EXT`, `INT/EXT`.
        public var setting: String
        public var location: String
        public var time: String
        public var eighths: Int
        /// The printed page it starts on.
        public var page: String
        /// Speaking characters, in order of first line.
        public var cast: [String]
        /// Speeches and dialogue words per character.
        public var speeches: [String: Int]
        public var words: [String: Int]
    }

    public struct CharacterRow: Sendable, Equatable {
        public var name: String
        public var scenes: [String]
        public var speeches: Int
        public var words: Int
        public var firstPage: String
    }

    public struct LocationRow: Sendable, Equatable {
        public var location: String
        public var settings: [String]
        public var scenes: [String]
        public var eighths: Int
    }

    public static func scenes(files: [ParsedScript], paginated: PaginatedScript, labels: [String]) -> [SceneRow] {
        // The first page each scene appears on.
        var firstPage: [Int: String] = [:]
        for page in paginated.pages {
            for row in page.rows { if let scene = row.line.scene, firstPage[scene] == nil { firstPage[scene] = page.label } }
        }
        var rows: [SceneRow] = []
        for parsed in files {
            for scene in parsed.scenes {
                let index = rows.count
                let heading = SceneHeading.parse(parsed.lines[scene.headingLine].text)
                let parts = heading.parts
                var cast: [String] = [], speeches: [String: Int] = [:], words: [String: Int] = [:]
                var speaker: String?
                for lineIndex in scene.lines where parsed.lines.indices.contains(lineIndex) {
                    let line = parsed.lines[lineIndex]
                    switch line.kind {
                    case .character:
                        speaker = ScriptParser.characterName(fromCue: ScriptEstimate.printedText(of: line))
                        if let speaker {
                            if !cast.contains(speaker) { cast.append(speaker) }
                            speeches[speaker, default: 0] += 1
                        }
                    case .dialogue:
                        if let speaker { words[speaker, default: 0] += ScriptEstimate.words(in: line) }
                    case .parenthetical, .blank:
                        break
                    default:
                        speaker = nil
                    }
                }
                rows.append(SceneRow(
                    index: index,
                    number: labels.indices.contains(index) ? labels[index] : String(index + 1),
                    id: scene.sceneID,
                    heading: heading.heading,
                    setting: setting(parts.prefix),
                    location: parts.location.uppercased(),
                    time: parts.time?.uppercased() ?? "",
                    eighths: paginated.sceneEighths.indices.contains(index) ? paginated.sceneEighths[index] : 0,
                    page: firstPage[index] ?? "",
                    cast: cast, speeches: speeches, words: words
                ))
            }
        }
        return rows
    }

    /// `INT.` → `INT`, `I/E` → `INT/EXT`.
    static func setting(_ prefix: String?) -> String {
        guard let prefix = prefix?.uppercased() else { return "" }
        if prefix.hasPrefix("I/E") || prefix.contains("/") { return "INT/EXT" }
        if prefix.hasPrefix("INT") { return "INT" }
        if prefix.hasPrefix("EXT") { return "EXT" }
        if prefix.hasPrefix("EST") { return "EST" }
        return prefix
    }

    /// Characters with the most scenes first.
    public static func characters(_ scenes: [SceneRow]) -> [CharacterRow] {
        var byName: [String: CharacterRow] = [:]
        var order: [String] = []
        for scene in scenes {
            for name in scene.cast {
                if byName[name] == nil {
                    byName[name] = CharacterRow(name: name, scenes: [], speeches: 0, words: 0, firstPage: scene.page)
                    order.append(name)
                }
                byName[name]!.scenes.append(scene.number)
                byName[name]!.speeches += scene.speeches[name] ?? 0
                byName[name]!.words += scene.words[name] ?? 0
            }
        }
        return order.compactMap { byName[$0] }.enumerated()
            .sorted { $0.element.scenes.count != $1.element.scenes.count ? $0.element.scenes.count > $1.element.scenes.count : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Locations in order of first appearance.
    public static func locations(_ scenes: [SceneRow]) -> [LocationRow] {
        var byName: [String: LocationRow] = [:]
        var order: [String] = []
        for scene in scenes where !scene.location.isEmpty {
            if byName[scene.location] == nil {
                byName[scene.location] = LocationRow(location: scene.location, settings: [], scenes: [], eighths: 0)
                order.append(scene.location)
            }
            if !scene.setting.isEmpty, !byName[scene.location]!.settings.contains(scene.setting) {
                byName[scene.location]!.settings.append(scene.setting)
            }
            byName[scene.location]!.scenes.append(scene.number)
            byName[scene.location]!.eighths += scene.eighths
        }
        return order.compactMap { byName[$0] }
    }

    /// RFC 4180 CSV: fields with commas, quotes or line breaks are quoted.
    public static func csv(header: [String], rows: [[String]]) -> String {
        func field(_ text: String) -> String {
            guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
