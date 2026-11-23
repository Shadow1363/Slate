import Foundation

/// How a note's infobox arranges its fields, read from a `layout:` list in
/// the note or its template (the wiki-infobox format):
///
/// ```yaml
/// layout:
/// - type: header
///   text: Powers
///   above: powers1
/// - type: columns
///   keys: [powers1, powers2]
/// ```
public enum InfoboxLayout {
    public enum Item: Sendable, Equatable {
        /// A section header, placed above `above` (or above the next item's first key).
        case header(text: String, above: String?)
        /// Fields shown side by side.
        case columns([String])
        /// The picture at the top of the infobox.
        case image(String)
        /// A field the infobox should show even if it's empty.
        case field(String)
    }

    /// One line of a resolved infobox.
    public enum Row: Sendable, Equatable {
        case header(String)
        case field(String)
        case columns([String])
    }

    /// Reads a `layout:` value. Unknown item types are skipped (the file keeps them).
    public static func parse(_ value: YAMLValue?) -> [Item] {
        guard case .list(let entries)? = value else { return [] }
        return entries.compactMap { entry -> Item? in
            let kind = entry["type"]?.text.lowercased() ?? ""
            switch kind {
            case "header", "heading", "section":
                let text = entry["text"]?.text ?? entry["label"]?.text ?? ""
                let above = entry["above"]?.text
                return .header(text: text, above: above?.isEmpty == false ? above : nil)
            case "columns", "row":
                let keys = entry["keys"]?.items ?? []
                return keys.isEmpty ? nil : .columns(keys)
            case "image", "portrait":
                return entry["key"].map { .image($0.text) }
            case "field":
                return entry["key"].map { .field($0.text) }
            default:
                return nil
            }
        }
    }

    /// The `layout:` list as YAML lines (block style, as people write it).
    public static func emitLines(_ items: [Item]) -> [String] {
        var lines: [String] = []
        func key(_ value: String) -> String { Frontmatter.emit(.string(value)) }
        for item in items {
            switch item {
            case .header(let text, let above):
                lines.append("  - type: header")
                lines.append("    text: \(key(text))")
                if let above { lines.append("    above: \(key(above))") }
            case .columns(let keys):
                lines.append("  - type: columns")
                lines.append("    keys: \(Frontmatter.emit(.list(keys.map { .string($0) })))")
            case .image(let k):
                lines.append("  - type: image")
                lines.append("    key: \(key(k))")
            case .field(let k):
                lines.append("  - type: field")
                lines.append("    key: \(key(k))")
            }
        }
        return lines
    }

    /// Keys an infobox never lists as rows: the name, type and layout themselves.
    public static let structuralKeys: Set<String> = ["type", "id", "infobox", "layout", "name", "title", "subtitle"]

    /// The image key shown at the top: the layout's `image`, else the first
    /// image field, else a key called image, portrait or picture.
    public static func imageKey(layout: [Item], fields: [NoteTemplate.Field], noteKeys: [String]) -> String? {
        for item in layout { if case .image(let key) = item { return key } }
        if let field = fields.first(where: { $0.type == .image }) { return field.key }
        return noteKeys.first { ["image", "portrait", "picture", "img"].contains($0.lowercased()) }
    }

    /// The infobox rows: template fields in order, then the note's other
    /// keys in file order, grouped into columns and given headers by the
    /// layout. Nothing in the note is left out.
    public static func rows(templateKeys: [String], noteKeys: [String], layout: [Item], excluding: Set<String>) -> [Row] {
        var order: [String] = []
        for key in templateKeys + noteKeys where !excluding.contains(key) && !order.contains(key) {
            order.append(key)
        }
        for item in layout {
            if case .field(let key) = item, !excluding.contains(key), !order.contains(key) { order.append(key) }
        }

        // Column groups, by the key that starts them.
        var groupOf: [String: [String]] = [:]
        for item in layout {
            guard case .columns(let keys) = item else { continue }
            let present = keys.filter { order.contains($0) }
            guard present.count > 1 else { continue }
            for key in present where groupOf[key] == nil { groupOf[key] = present }
        }

        // Headers, by the key they sit above.
        var headersAbove: [String: [String]] = [:]
        var trailing: [String] = []
        for (index, item) in layout.enumerated() {
            guard case .header(let text, let above) = item else { continue }
            var target = above.flatMap { order.contains($0) ? $0 : nil }
            if target == nil {
                // No `above`: the first key of the next item that has one.
                for next in layout[(index + 1)...] {
                    switch next {
                    case .columns(let keys): target = keys.first { order.contains($0) }
                    case .field(let key) where order.contains(key): target = key
                    default: break
                    }
                    if target != nil { break }
                }
            }
            if let target {
                headersAbove[groupOf[target]?.first ?? target, default: []].append(text)
            } else {
                trailing.append(text)
            }
        }

        var rows: [Row] = []
        var done = Set<String>()
        for key in order where !done.contains(key) {
            if let group = groupOf[key] {
                let lead = group.first!
                for text in headersAbove[lead] ?? [] { rows.append(.header(text)) }
                rows.append(.columns(group))
                done.formUnion(group)
            } else {
                for text in headersAbove[key] ?? [] { rows.append(.header(text)) }
                rows.append(.field(key))
                done.insert(key)
            }
        }
        rows += trailing.map { .header($0) }
        return rows
    }

    // MARK: - The template editor's simpler model

    /// Where a field sits: under a new section header, and/or beside the previous field.
    public struct Placement: Sendable, Equatable {
        public var key: String
        public var section: String?
        public var besidePrevious: Bool

        public init(key: String, section: String? = nil, besidePrevious: Bool = false) {
            self.key = key
            self.section = section
            self.besidePrevious = besidePrevious
        }
    }

    /// A layout as per-field placements, for `keys` in order.
    public static func placements(for keys: [String], layout: [Item]) -> [Placement] {
        var sections: [String: String] = [:]
        var beside = Set<String>()
        for (index, item) in layout.enumerated() {
            switch item {
            case .header(let text, let above):
                var target = above
                if target == nil {
                    for next in layout[(index + 1)...] {
                        if case .columns(let keys) = next { target = keys.first; break }
                        if case .field(let key) = next { target = key; break }
                    }
                }
                if let target { sections[target] = text }
            case .columns(let keys):
                for key in keys.dropFirst() { beside.insert(key) }
            default:
                break
            }
        }
        return keys.map { Placement(key: $0, section: sections[$0], besidePrevious: beside.contains($0)) }
    }

    /// Placements back to layout items. `extra` (image and field items) are kept.
    public static func layout(from placements: [Placement], keeping extra: [Item] = []) -> [Item] {
        var items: [Item] = []
        var index = 0
        while index < placements.count {
            let placement = placements[index]
            if let section = placement.section?.trimmingCharacters(in: .whitespaces), !section.isEmpty {
                items.append(.header(text: section, above: placement.key))
            }
            var group = [placement.key]
            var next = index + 1
            while next < placements.count, placements[next].besidePrevious {
                group.append(placements[next].key)
                next += 1
            }
            if group.count > 1 { items.append(.columns(group)) }
            // A header inside a column group still sits above the group.
            for inner in placements[(index + 1)..<next] {
                if let section = inner.section?.trimmingCharacters(in: .whitespaces), !section.isEmpty {
                    items.append(.header(text: section, above: inner.key))
                }
            }
            index = next
        }
        return items + extra.filter {
            switch $0 {
            case .image, .field: true
            default: false
            }
        }
    }
}

/// `||hidden text||`: a spoiler, blacked out until clicked. The file keeps the bars.
public enum Spoiler {
    public struct Piece: Sendable, Equatable {
        public let text: String
        public let isSpoiler: Bool
    }

    /// Ranges of whole spoilers, bars included.
    public static func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    /// The text split into plain and spoiler pieces (bars removed).
    public static func pieces(_ text: String) -> [Piece] {
        let ns = text as NSString
        var pieces: [Piece] = []
        var last = 0
        for range in ranges(in: text) {
            if range.location > last {
                pieces.append(Piece(text: ns.substring(with: NSRange(location: last, length: range.location - last)), isSpoiler: false))
            }
            pieces.append(Piece(text: ns.substring(with: NSRange(location: range.location + 2, length: range.length - 4)), isSpoiler: true))
            last = NSMaxRange(range)
        }
        if last < ns.length {
            pieces.append(Piece(text: ns.substring(from: last), isSpoiler: false))
        }
        return pieces
    }

    public static func contains(_ text: String) -> Bool { !ranges(in: text).isEmpty }

    static let pattern = try! NSRegularExpression(pattern: #"\|\|(?!\|)(.+?)\|\|"#)
}

/// Saves, copies and removes template files.
public enum TemplateLibrary {
    public enum Location: String, Sendable, CaseIterable {
        case project, global
    }

    /// Writes a template as `<type>.md` in the chosen folder. If it was read
    /// from a different file (renamed type, or moved between project and
    /// global), that file is moved to the Trash. Built-ins are never touched.
    @discardableResult
    public static func save(_ template: NoteTemplate, to location: Location, replacing old: NoteTemplate?,
                            projectTemplates: URL, globalTemplates: URL) throws -> URL {
        let folder = location == .project ? projectTemplates : globalTemplates
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: Slug.make(template.type) + ".md")
        try CoordinatedFileIO.writeText(template.text, to: url)
        // Saving a type brings it back if it had been deleted.
        for folder in [projectTemplates, globalTemplates] {
            for tombstone in NoteTemplates.tombstones(in: folder)
            where tombstone.template.type == template.type && tombstone.url.standardizedFileURL != url.standardizedFileURL {
                try CoordinatedFileIO.trash(tombstone.url)
            }
        }
        if let old, let oldURL = fileURL(of: old, projectTemplates: projectTemplates, globalTemplates: globalTemplates),
           oldURL.standardizedFileURL != url.standardizedFileURL,
           FileManager.default.fileExists(atPath: oldURL.path) {
            try CoordinatedFileIO.trash(oldURL)
        }
        return url
    }

    /// Moves a project or global template to the Trash (a built-in of the
    /// same type takes over again).
    public static func remove(_ template: NoteTemplate, projectTemplates: URL, globalTemplates: URL) throws {
        guard let url = fileURL(of: template, projectTemplates: projectTemplates, globalTemplates: globalTemplates),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try CoordinatedFileIO.trash(url)
    }

    /// Deletes a template, built-ins too. Its own file goes to the Trash; if
    /// another template of the type would show through (Slate's built-in, or an
    /// every-project one under a project one), a `removed: true` file hides it.
    /// A built-in is deleted from `location`: this project, or every project.
    public static func delete(_ template: NoteTemplate, from location: Location, projectTemplates: URL, globalTemplates: URL) throws {
        let folder: URL
        switch template.origin {
        case .builtIn: folder = location == .project ? projectTemplates : globalTemplates
        case .project: folder = projectTemplates
        case .global: folder = globalTemplates
        }
        if let own = fileURL(of: template, projectTemplates: projectTemplates, globalTemplates: globalTemplates),
           FileManager.default.fileExists(atPath: own.path) {
            try CoordinatedFileIO.trash(own)
        }
        let still = NoteTemplates.load(projectTemplates: template.origin == .global ? nil : projectTemplates, globalTemplates: globalTemplates)
        let showsThrough = template.origin == .global
            ? NoteTemplates.load(projectTemplates: nil, globalTemplates: globalTemplates).contains { $0.type == template.type }
            : still.contains { $0.type == template.type }
        guard showsThrough || template.origin == .builtIn else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try CoordinatedFileIO.writeText(NoteTemplate.tombstone(type: template.type, label: template.label),
                                        to: folder.appending(path: Slug.make(template.type) + ".md"))
    }

    /// Brings a deleted template back by moving its `removed: true` files to the Trash.
    public static func restore(type: String, projectTemplates: URL, globalTemplates: URL) throws {
        for folder in [projectTemplates, globalTemplates] {
            for tombstone in NoteTemplates.tombstones(in: folder) where tombstone.template.type == type {
                try CoordinatedFileIO.trash(tombstone.url)
            }
        }
    }

    public static func fileURL(of template: NoteTemplate, projectTemplates: URL, globalTemplates: URL) -> URL? {
        switch template.origin {
        case .builtIn: nil
        case .project: projectTemplates.appending(path: template.fileName)
        case .global: globalTemplates.appending(path: template.fileName)
        }
    }

    /// A type and folder for a new template called `label`, not clashing with `existing` types.
    public static func newType(label: String, existing: Set<String>) -> (type: String, folder: String) {
        let base = Slug.make(label)
        var type = base
        var counter = 2
        while existing.contains(type) {
            type = "\(base)-\(counter)"
            counter += 1
        }
        return (type, type.hasSuffix("s") ? type : type + "s")
    }

    /// Whether a built-in template has this type (so an override can be reverted).
    public static func hasBuiltIn(_ type: String) -> Bool {
        NoteTemplates.builtInOrder.contains(type)
    }
}

extension NoteTemplates {
    /// The template a note's `type:` or `infobox:` value names, by type or
    /// label, ignoring case.
    public static func matching(_ value: String?, in templates: [NoteTemplate]) -> NoteTemplate? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let key = value.lowercased()
        return templates.first { $0.type.lowercased() == key }
            ?? templates.first { $0.label.lowercased() == key }
            ?? templates.first { Slug.make($0.label) == Slug.make(value) }
    }
}
