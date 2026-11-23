import Foundation

/// Tags on universe notes (`tags: [good, protagonist]` in the frontmatter) and
/// on scenes (`{#s014 tags=storm,flashback}` in the scene tag).
///
/// Tags are normalised: lowercase, no `#`, spaces as dashes. "Good Guy" is `good-guy`.
public enum Tags {
    public static func normalize(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        let parts = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "}" || $0 == "{" || $0 == "=" })
        return parts.joined(separator: "-")
    }

    /// `storm, Flash Back` → `["storm", "flash-back"]`, without repeats.
    public static func parseList(_ text: String) -> [String] {
        unique(text.split(separator: ",").map { normalize(String($0)) })
    }

    public static func unique(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.map(normalize).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The `tags=` value for a scene tag, or nil for none.
    public static func attribute(_ tags: [String]) -> String? {
        let list = unique(tags)
        return list.isEmpty ? nil : list.joined(separator: ",")
    }

    /// A note's text with its `tags:` list replaced (removed when empty).
    public static func settingNoteTags(_ tags: [String], in text: String) -> String {
        Frontmatter.setting("tags", to: .list(unique(tags).map { .string($0) }), in: text)
    }

    /// A note's tags, normalised.
    public static func noteTags(_ note: Note) -> [String] { unique(note.tags) }

    /// The text of a note with `tag` renamed to `new` (or removed when nil); unchanged if it hasn't got it.
    public static func renaming(_ tag: String, to new: String?, inNote text: String, path: String) -> String {
        let tag = normalize(tag)
        let note = Note(path: path, text: text)
        let current = noteTags(note)
        guard current.contains(tag) else { return text }
        let updated = current.compactMap { $0 == tag ? new.map(normalize) : $0 }
        return settingNoteTags(updated, in: text)
    }

    /// An act file with `tag` renamed (or removed) on every scene that has it.
    public static func renaming(_ tag: String, to new: String?, inScript text: String) -> String {
        let tag = normalize(tag)
        var result = text
        for scene in ScriptParser.parse(text).scenes where scene.tags.contains(tag) {
            let updated = scene.tags.compactMap { $0 == tag ? new.map(normalize) : $0 }
            result = SceneEditing.settingAttribute("tags", to: attribute(updated), headingLine: scene.headingLine, in: result)
        }
        return result
    }
}

/// Every tag in a project, and what carries it.
public struct TagIndex: Sendable, Equatable {
    public enum Ref: Sendable, Equatable, Hashable {
        case note(path: String, name: String)
        case scene(id: String, heading: String, film: String?)
    }

    public private(set) var refs: [String: [Ref]] = [:]

    public init(notes: [Note], scenes: [(id: String, heading: String, film: String?, tags: [String])]) {
        for note in notes {
            for tag in Tags.noteTags(note) { refs[tag, default: []].append(.note(path: note.path, name: note.name)) }
        }
        for scene in scenes {
            for tag in Tags.unique(scene.tags) { refs[tag, default: []].append(.scene(id: scene.id, heading: scene.heading, film: scene.film)) }
        }
    }

    /// Tags, most used first.
    public var tags: [(tag: String, count: Int)] {
        refs.map { ($0.key, $0.value.count) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    public func count(_ tag: String) -> Int { refs[Tags.normalize(tag)]?.count ?? 0 }
}
