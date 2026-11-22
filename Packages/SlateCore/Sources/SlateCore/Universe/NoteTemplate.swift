import Foundation

/// A note template: a `.md` file whose frontmatter names the note type, its
/// folder under `universe/`, and its fields; its body is the starter headings.
///
/// ```markdown
/// ---
/// type: character
/// folder: characters
/// fields:
///   name: text
///   age: number
///   when: {type: text, label: When (world time)}
/// ---
/// ## Want
/// ```
public struct NoteTemplate: Sendable, Equatable, Identifiable {
    public enum FieldType: String, Sendable, CaseIterable, Codable {
        case text, number, date, list, link, image
    }

    public struct Field: Sendable, Equatable, Identifiable {
        public let key: String
        public let type: FieldType
        public let label: String
        public var id: String { key }

        public init(key: String, type: FieldType, label: String? = nil) {
            self.key = key
            self.type = type
            self.label = label ?? key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    public enum Origin: Sendable, Equatable {
        case builtIn, global, project
    }

    /// The note type written to `type:`, e.g. `character`.
    public let type: String
    /// Folder under `universe/`, e.g. `characters`.
    public let folder: String
    /// Shown in menus, e.g. "Character".
    public let label: String
    public let fields: [Field]
    public let body: String
    public let origin: Origin
    public var id: String { type }

    /// Parses a template file. The type falls back to the file name.
    public init(text: String, fileName: String, origin: Origin) throws {
        let fields = try Frontmatter.fields(in: text)
        func string(_ key: String) -> String? {
            fields.first { $0.key == key }.map(\.value.text).flatMap { $0.isEmpty ? nil : $0 }
        }
        let stem = (fileName as NSString).deletingPathExtension
        type = string("type") ?? stem
        folder = string("folder") ?? type + "s"
        label = string("label") ?? type.prefix(1).uppercased() + type.dropFirst()
        var declared: [Field] = []
        if case .map(let entries)? = fields.first(where: { $0.key == "fields" })?.value {
            for entry in entries {
                switch entry.value {
                case .string(let name):
                    declared.append(Field(key: entry.key, type: FieldType(rawValue: name.lowercased()) ?? .text))
                case .map:
                    let kind = entry.value["type"]?.text.lowercased() ?? "text"
                    let label = entry.value["label"]?.text
                    declared.append(Field(key: entry.key, type: FieldType(rawValue: kind) ?? .text, label: label?.isEmpty == false ? label : nil))
                default:
                    declared.append(Field(key: entry.key, type: .text))
                }
            }
        }
        if !declared.contains(where: { $0.key == "name" }) {
            declared.insert(Field(key: "name", type: .text), at: 0)
        }
        self.fields = declared
        body = Frontmatter.split(text).body
        self.origin = origin
    }

    /// The letter that starts this type's note IDs: `c-7f3a` for a character.
    public var idPrefix: String {
        String(type.first.map { $0.lowercased() } ?? "n")
    }

    /// The text of a new note made from this template.
    public func newNote(name: String, id: String) -> String {
        var lines = ["---", "type: \(Frontmatter.emit(.string(type)))", "id: \(id)"]
        for field in fields {
            if field.key == "name" {
                lines.append(Frontmatter.emit(key: "name", value: .string(name)))
            } else if field.type == .list {
                lines.append("\(field.key): []")
            } else {
                lines.append("\(field.key):")
            }
        }
        lines.append("---")
        let body = body.isEmpty ? "" : body.hasSuffix("\n") ? body : body + "\n"
        return lines.joined(separator: "\n") + "\n" + body
    }

    /// A random note ID such as `c-7f3a`, not in `existing`.
    public func newID(existing: Set<String>) -> String {
        while true {
            let id = idPrefix + "-" + String(format: "%04x", Int.random(in: 0..<0x10000))
            if !existing.contains(id) { return id }
        }
    }

    /// Path of a new note: `universe/<folder>/<slug>.md`, made unique.
    public func path(forName name: String, existing: Set<String>) -> String {
        NoteTemplate.uniquePath(folder: "universe/" + folder, stem: Slug.make(name), existing: existing)
    }

    static func uniquePath(folder: String, stem: String, existing: Set<String>) -> String {
        let lowered = Set(existing.map { $0.lowercased() })
        var candidate = "\(folder)/\(stem).md"
        var counter = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = "\(folder)/\(stem)-\(counter).md"
            counter += 1
        }
        return candidate
    }
}

/// Finds templates: project `templates/`, then the global folder, then built-ins.
public enum NoteTemplates {
    public static let builtInOrder = ["character", "location", "rule", "faction", "item", "event", "note"]

    public static var builtIn: [NoteTemplate] {
        builtInOrder.compactMap { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Templates"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return try? NoteTemplate(text: text, fileName: name + ".md", origin: .builtIn)
        }
    }

    /// All templates, overrides replacing built-ins with the same type.
    /// Unreadable template files are skipped.
    public static func load(projectTemplates: URL?, globalTemplates: URL?) -> [NoteTemplate] {
        var byType: [String: NoteTemplate] = [:]
        var order: [String] = []
        func add(_ template: NoteTemplate) {
            if byType[template.type] == nil { order.append(template.type) }
            byType[template.type] = template
        }
        builtIn.forEach(add)
        for (folder, origin) in [(globalTemplates, NoteTemplate.Origin.global), (projectTemplates, .project)] {
            guard let folder,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where name.lowercased().hasSuffix(".md") && !name.hasPrefix(".") {
                let url = folder.appending(path: name)
                guard let text = try? CoordinatedFileIO.readText(url),
                      let template = try? NoteTemplate(text: text, fileName: name, origin: origin) else { continue }
                add(template)
            }
        }
        return order.compactMap { byType[$0] }
    }
}

/// File-name slugs: "Mara Voss" → `mara-voss`.
public enum Slug {
    public static func make(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var slug = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !slug.isEmpty { slug += "-" }
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else if scalar != "'" && scalar != "’" {
                pendingDash = true
            }
        }
        return slug.isEmpty ? "untitled" : slug
    }
}
