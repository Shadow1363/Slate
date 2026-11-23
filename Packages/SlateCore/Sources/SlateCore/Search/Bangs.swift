import Foundation

/// What a bang limits Search to.
public enum SearchScope: Hashable, Sendable {
    /// Notes of one template type (`!c` → `character`).
    case template(String)
    case universe, draft, canvas, timeline, map
    case scene, film, act, cue, extra
    case frame
    case todo, marginNote
    case word, tag, file, text

    /// The key area bangs are saved under in preferences.
    public var key: String {
        switch self {
        case .template(let type): "template:" + type
        case .universe: "universe"
        case .draft: "draft"
        case .canvas: "canvas"
        case .timeline: "timeline"
        case .map: "map"
        case .scene: "scene"
        case .film: "film"
        case .act: "act"
        case .cue: "cue"
        case .extra: "extra"
        case .frame: "frame"
        case .todo: "todo"
        case .marginNote: "marginNote"
        case .word: "word"
        case .tag: "tag"
        case .file: "file"
        case .text: "text"
        }
    }
}

/// A bang such as `!c`: its name (without `!`), what it searches, and a line of help.
public struct Bang: Sendable, Equatable, Identifiable {
    public let name: String
    public let scope: SearchScope
    public let title: String
    public let help: String
    public var id: String { scope.key }

    public init(name: String, scope: SearchScope, title: String, help: String) {
        self.name = name
        self.scope = scope
        self.title = title
        self.help = help
    }
}

public enum Bangs {
    /// Lowercase letters and digits only: `!Cue` → `cue`.
    public static func normalize(_ name: String) -> String {
        String(name.lowercased().drop { $0 == "!" }.filter { $0.isLetter || $0.isNumber })
    }

    /// The bangs that aren't templates, in the order Search lists them.
    public static let areas: [Bang] = [
        Bang(name: "u", scope: .universe, title: "Universe notes", help: "Every universe note, of any template"),
        Bang(name: "d", scope: .draft, title: "Rough draft", help: "Headings in the rough draft"),
        Bang(name: "cv", scope: .canvas, title: "Canvases", help: "Canvases and their text cards"),
        Bang(name: "tl", scope: .timeline, title: "Timeline events", help: "Events by title, when they happen and who's in them"),
        Bang(name: "m", scope: .map, title: "Map places", help: "Pins, regions and paths on every map"),
        Bang(name: "s", scope: .scene, title: "Scenes", help: "Scenes in every film. Try time:night, place:harbour, int:, ext:, color:red, film:2, long:"),
        Bang(name: "film", scope: .film, title: "Films", help: "The films of a saga. With another bang, the word after it picks the film: !film slack !s"),
        Bang(name: "act", scope: .act, title: "Acts", help: "Act files and their # sections"),
        Bang(name: "cue", scope: .cue, title: "Speeches", help: "A character's lines: !cue juno, or !cue juno tide"),
        Bang(name: "x", scope: .extra, title: "Transitions and notes", help: "Transitions, centred text and boneyard notes"),
        Bang(name: "b", scope: .frame, title: "Storyboard frames", help: "Frames by caption, shot and move. Try shot:CU, move:pan, empty:"),
        Bang(name: "todo", scope: .todo, title: "To-dos", help: "Open to-dos. done: shows finished ones; due: sorts by due date"),
        Bang(name: "mn", scope: .marginNote, title: "Margin notes", help: "Notes in the script's margin"),
        Bang(name: "w", scope: .word, title: "Dictionary", help: "Words, their meanings and forms"),
        Bang(name: "t", scope: .tag, title: "Tags", help: "!t alone lists tags; !t good protagonist finds what has both"),
        Bang(name: "file", scope: .file, title: "Files", help: "Any file, by name or path"),
        Bang(name: "text", scope: .text, title: "Text", help: "Every line containing the words. \"Quotes\" match exactly; / does the same"),
    ]

    /// Slate's own letters for the built-in templates.
    static let templateDefaults = ["character": "c", "location": "l", "rule": "r", "faction": "f", "item": "i", "event": "e", "note": "n"]

    /// Every bang: templates first (their own `bang:`, else a default), then the areas,
    /// with area names changed by `renames` (scope key → name).
    public static func all(templates: [NoteTemplate], renames: [String: String] = [:]) -> [Bang] {
        var areas = areas.map { bang -> Bang in
            guard let renamed = renames[bang.scope.key].map(normalize), !renamed.isEmpty else { return bang }
            return Bang(name: renamed, scope: bang.scope, title: bang.title, help: bang.help)
        }
        var taken: Set<String> = []
        var result: [Bang] = []
        // Templates with their own bang claim it first, even over an area's.
        var assigned: [String: String] = [:]
        for template in templates {
            if let own = template.bang, !taken.contains(own) {
                assigned[template.type] = own
                taken.insert(own)
            }
        }
        taken.formUnion(areas.map(\.name))
        for template in templates where assigned[template.type] == nil {
            var name = templateDefaults[template.type].flatMap { taken.contains($0) ? nil : $0 }
            if name == nil {
                let letters = normalize(template.type.isEmpty ? template.label : template.type)
                for length in 1...max(1, letters.count) where name == nil {
                    let candidate = String(letters.prefix(length))
                    if !candidate.isEmpty, !taken.contains(candidate) { name = candidate }
                }
                var n = 2
                while name == nil || taken.contains(name!) {
                    name = letters + String(n)
                    n += 1
                }
            }
            assigned[template.type] = name!
            taken.insert(name!)
        }
        for template in templates {
            result.append(Bang(name: assigned[template.type]!, scope: .template(template.type), title: template.label,
                               help: "\(template.label) notes"))
        }
        areas.removeAll { area in result.contains { $0.name == area.name } }
        return result + areas
    }

    /// Bang names that more than one thing wants (shown as a problem in Settings and Templates).
    public static func clashes(templates: [NoteTemplate], renames: [String: String]) -> Set<String> {
        var names: [String: Int] = [:]
        for template in templates { if let bang = template.bang { names[bang, default: 0] += 1 } }
        for area in areas { names[renames[area.scope.key].map(normalize) ?? area.name, default: 0] += 1 }
        return Set(names.filter { $0.value > 1 }.keys)
    }
}
