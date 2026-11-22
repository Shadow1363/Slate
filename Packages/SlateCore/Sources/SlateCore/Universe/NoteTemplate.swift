import Foundation

/// A note template: a `.md` file whose frontmatter names the note type, its
/// folder under `universe/`, its fields and how the infobox lays them out;
/// its body is the starter headings.
///
/// ```markdown
/// ---
/// type: character
/// label: Character
/// folder: characters
/// icon: person
/// fields:
///   name: text
///   role: {type: choice, label: Role, options: [lead, ally, foe]}
///   backstory: longtext
///   alive: bool
///   powers: links
/// layout:
///   - type: header
///     text: Powers
///     above: powers
/// ---
/// ## Want
/// ```
public struct NoteTemplate: Sendable, Equatable, Identifiable {
    public enum FieldType: String, Sendable, CaseIterable, Codable, Identifiable {
        case text, longText = "longtext", number, date, choice, bool, list, link, links, image

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .text: "Text"
            case .longText: "Long text"
            case .number: "Number"
            case .date: "Date"
            case .choice: "Choice"
            case .bool: "Yes/No"
            case .list: "List"
            case .link: "Link"
            case .links: "Links"
            case .image: "Image"
            }
        }

        /// Reads a type name, accepting common spellings ("long text", "checkbox", …).
        public static func named(_ name: String) -> FieldType {
            let key = name.lowercased().filter { $0.isLetter }
            switch key {
            case "longtext", "long", "multiline", "paragraph", "textarea": return .longText
            case "bool", "boolean", "yesno", "checkbox", "toggle": return .bool
            case "choice", "select", "dropdown", "option", "enum": return .choice
            default: return FieldType(rawValue: key) ?? .text
            }
        }
    }

    public struct Field: Sendable, Equatable, Identifiable {
        public var key: String
        public var type: FieldType
        public var label: String
        /// The choices, for a `choice` field.
        public var options: [String]
        public var id: String { key }

        public init(key: String, type: FieldType, label: String? = nil, options: [String] = []) {
            self.key = key
            self.type = type
            self.label = label ?? Field.defaultLabel(for: key)
            self.options = options
        }

        public static func defaultLabel(for key: String) -> String {
            key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    public enum Origin: Sendable, Equatable {
        case builtIn, global, project
    }

    /// The note type written to `type:`, e.g. `character`.
    public var type: String
    /// Folder under `universe/`, e.g. `characters`.
    public var folder: String
    /// Shown in menus, e.g. "Character".
    public var label: String
    /// An SF Symbol name for menus and the sidebar, if set.
    public var icon: String?
    /// The key holding the note's name: `name` or `title`.
    public var nameField: String
    public var fields: [Field]
    /// How the infobox arranges the fields (a note's own `layout:` wins).
    public var layout: [InfoboxLayout.Item]
    public var body: String
    public var origin: Origin
    /// The file it was read from, e.g. `character.md`.
    public var fileName: String
    public var id: String { type }

    public init(type: String, label: String, folder: String, icon: String? = nil, nameField: String = "name",
                fields: [Field], layout: [InfoboxLayout.Item] = [], body: String = "", origin: Origin, fileName: String? = nil) {
        self.type = type
        self.label = label
        self.folder = folder
        self.icon = icon
        self.nameField = nameField
        self.fields = fields
        self.layout = layout
        self.body = body
        self.origin = origin
        self.fileName = fileName ?? type + ".md"
        ensureNameField()
    }

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
        icon = string("icon")
        nameField = string("nameField") ?? "name"
        var declared: [Field] = []
        if case .map(let entries)? = fields.first(where: { $0.key == "fields" })?.value {
            for entry in entries {
                switch entry.value {
                case .string(let name):
                    declared.append(Field(key: entry.key, type: .named(name)))
                case .map:
                    let kind = FieldType.named(entry.value["type"]?.text ?? "text")
                    let label = entry.value["label"]?.text
                    let options = entry.value["options"]?.items ?? []
                    declared.append(Field(key: entry.key, type: kind, label: label?.isEmpty == false ? label : nil, options: options))
                default:
                    declared.append(Field(key: entry.key, type: .text))
                }
            }
        }
        self.fields = declared
        layout = InfoboxLayout.parse(fields.first { $0.key == "layout" }?.value)
        body = Frontmatter.split(text).body
        self.origin = origin
        self.fileName = fileName
        ensureNameField()
    }

    private mutating func ensureNameField() {
        if !fields.contains(where: { $0.key == nameField }) {
            fields.insert(Field(key: nameField, type: .text), at: 0)
        }
    }

    public func field(_ key: String) -> Field? {
        fields.first { $0.key == key }
    }

    /// The template written back as a file.
    public var text: String {
        var lines = ["---", "type: \(Frontmatter.emit(.string(type)))", "label: \(Frontmatter.emit(.string(label)))",
                     "folder: \(Frontmatter.emit(.string(folder)))"]
        if let icon, !icon.isEmpty { lines.append("icon: \(Frontmatter.emit(.string(icon)))") }
        if nameField != "name" { lines.append("nameField: \(Frontmatter.emit(.string(nameField)))") }
        lines.append("fields:")
        for field in fields {
            let key = Frontmatter.emitKey(field.key)
            let plainLabel = field.label == Field.defaultLabel(for: field.key)
            if plainLabel, field.options.isEmpty {
                lines.append("  \(key): \(field.type.rawValue)")
            } else {
                var parts = ["type: \(field.type.rawValue)"]
                if !plainLabel { parts.append("label: \(Frontmatter.emit(.string(field.label)))") }
                if !field.options.isEmpty { parts.append("options: \(Frontmatter.emit(.list(field.options.map { .string($0) })))") }
                lines.append("  \(key): {" + parts.joined(separator: ", ") + "}")
            }
        }
        if !layout.isEmpty {
            lines.append("layout:")
            lines += InfoboxLayout.emitLines(layout)
        }
        lines.append("---")
        let body = body.isEmpty ? "" : body.hasSuffix("\n") ? body : body + "\n"
        return lines.joined(separator: "\n") + "\n" + body
    }

    /// The letter that starts this type's note IDs: `c-7f3a` for a character.
    public var idPrefix: String {
        String(type.first.map { $0.lowercased() } ?? "n")
    }

    /// The text of a new note made from this template.
    public func newNote(name: String, id: String) -> String {
        var lines = ["---", "type: \(Frontmatter.emit(.string(type)))", "id: \(id)"]
        for field in fields {
            let key = Frontmatter.emitKey(field.key)
            if field.key == nameField {
                lines.append(Frontmatter.emit(key: field.key, value: .string(name)))
            } else if field.type == .list || field.type == .links {
                lines.append("\(key): []")
            } else {
                lines.append("\(key):")
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
