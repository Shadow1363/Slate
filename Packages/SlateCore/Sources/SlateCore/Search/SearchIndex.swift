import Foundation

/// Where a Search result goes when it's picked.
public enum SearchTarget: Sendable, Equatable, Hashable {
    /// A file, optionally at a UTF-16 location.
    case path(String, location: Int?)
    case scene(String)
    case film(String)
    case word(String)
    case todo(line: Int, sceneID: String?, quote: String?)
    case marginNote(sceneID: String?, quote: String?)
    case timelineEvent(path: String, id: String)
    case mapItem(path: String, id: String)
    case frame(folder: String, file: String?, sceneID: String)
    case tag(String)
}

/// One thing Search can find.
public struct SearchItem: Sendable, Equatable, Identifiable {
    public var scope: SearchScope
    /// The section it's listed under: "Characters", "Scenes"…
    public var group: String
    public var title: String
    public var subtitle: String
    /// SF Symbol.
    public var icon: String
    public var target: SearchTarget
    public var tags: [String]
    /// Filterable fields, lowercase keys: `role`, `time`, `int`, `film`, `shot`…
    public var fields: [String: String]
    /// Other text that matches (aliases, captions, dialogue).
    public var keywords: [String]
    public var id: String

    public init(scope: SearchScope, group: String, title: String, subtitle: String = "", icon: String, target: SearchTarget,
                tags: [String] = [], fields: [String: String] = [:], keywords: [String] = [], id: String? = nil) {
        self.scope = scope
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.target = target
        self.tags = tags
        self.fields = fields
        self.keywords = keywords
        self.id = id ?? "\(scope.key)|\(target)|\(title)"
    }
}

public struct SearchSection: Sendable, Equatable, Identifiable {
    public let title: String
    public let items: [SearchItem]
    public var id: String { title }
}

public enum SearchEngine {
    /// Scopes a plain search (no bang) covers: names, not every line of dialogue.
    static func inPlainSearch(_ scope: SearchScope) -> Bool {
        switch scope {
        case .cue, .extra, .frame, .act, .marginNote, .text, .tag, .todo: false
        default: true
        }
    }

    /// The results for a query, grouped in the order the items came in.
    /// Full-text results (`!text`) are added by the caller.
    public static func search(_ query: SearchQuery, in items: [SearchItem], limitPerGroup: Int? = nil) -> [SearchSection] {
        let scopes = query.scopes.filter { $0 != .text }
        let filmOnly = scopes == [.film]
        // `!film x !s`: the film narrows the other bangs.
        let active = scopes.filter { ($0 != .film || filmOnly) && $0 != .tag }
        let listingTags = query.has(.tag) && query.tags.isEmpty
        let single = active.count == 1 || !query.tags.isEmpty || !query.filters.isEmpty
        let limit = limitPerGroup ?? (single || !active.isEmpty ? 200 : 8)
        if query.has(.text) && active.isEmpty { return [] }

        var candidates = items.filter { item in
            if listingTags && active.isEmpty { return item.scope == .tag }
            if active.isEmpty {
                // Tags alone (`!t good`, `#good`) cover notes and scenes that carry them; otherwise names.
                if !query.tags.isEmpty { return item.scope != .tag && inPlainSearch(item.scope) && !item.tags.isEmpty }
                return inPlainSearch(item.scope)
            }
            return active.contains { matches($0, item.scope) }
        }

        // Tags: every one must be on the item (the one being typed may be a prefix).
        for (index, tag) in query.tags.enumerated() {
            let prefix = index == query.tags.count - 1 && query.partial?.hasPrefix("#") == true
            candidates = candidates.filter { item in item.tags.contains { prefix ? $0.hasPrefix(tag) : $0 == tag } }
        }
        // Fields.
        for filter in query.filters {
            candidates = candidates.filter { matches(filter, $0) }
        }
        // Finished to-dos only when asked for.
        if query.filter("done") == nil { candidates.removeAll { $0.scope == .todo && $0.fields["done"] == "yes" } }

        var ranked: [SearchItem]
        if query.has(.cue) {
            ranked = rankSpeeches(candidates, text: query.text, exact: query.exact)
        } else {
            ranked = rank(candidates, text: query.text, exact: query.exact)
        }
        if query.filter("due") != nil {
            ranked.sort { ($0.fields["due"] ?? "~") < ($1.fields["due"] ?? "~") }
        }
        // Sections keep their place (notes, scenes, …); the best match leads within each.
        let order = Dictionary(items.enumerated().map { ($1.group, $0) }, uniquingKeysWith: { a, _ in a })
        return group(ranked, limit: limit).sorted { (order[$0.title] ?? .max) < (order[$1.title] ?? .max) }
    }

    static func matches(_ scope: SearchScope, _ itemScope: SearchScope) -> Bool {
        if scope == itemScope { return true }
        if scope == .universe, case .template = itemScope { return true }
        return false
    }

    static func matches(_ filter: SearchQuery.Filter, _ item: SearchItem) -> Bool {
        let value = LinkGraph.key(filter.value)
        if filter.key == "tag" || filter.key == "tags" {
            return value.isEmpty ? !item.tags.isEmpty : item.tags.contains { $0.hasPrefix(Tags.normalize(filter.value)) }
        }
        guard let field = item.fields.first(where: { $0.key.lowercased() == filter.key })?.value else { return false }
        let key = LinkGraph.key(field)
        if value.isEmpty { return !key.isEmpty && key != "no" && key != "false" }
        if filter.key == "film", let number = Int(value) { return item.fields["filmnumber"] == String(number) }
        return key.contains(value)
    }

    /// Best name matches first; with no words, the order given.
    static func rank(_ items: [SearchItem], text: String, exact: [String]) -> [SearchItem] {
        var items = items
        for phrase in exact {
            let key = LinkGraph.key(phrase)
            items = items.filter { item in ([item.title, item.subtitle] + item.keywords).contains { LinkGraph.key($0).contains(key) } }
        }
        let words = text.split(separator: " ").map { LinkGraph.key(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return items }
        // Words found as written win; letters in order ("mrv" for Mara Voss) only when nothing is.
        for fuzzy in [false, true] {
            let scored = items.enumerated().compactMap { index, item -> (Int, Int, SearchItem)? in
                let candidates = [item.title] + item.keywords + [item.subtitle]
                var total = 0
                for word in words {
                    // Each word must match somewhere; the title counts most.
                    let best = candidates.enumerated().compactMap { position, text -> Int? in
                        let key = LinkGraph.key(text)
                        guard fuzzy || key.contains(word) else { return nil }
                        return QuickOpen.score(word, in: key).map { position == 0 ? $0 : $0 / 2 }
                    }.max()
                    guard let best else { return nil }
                    total += best
                }
                return (total, index, item)
            }
            if !scored.isEmpty || fuzzy {
                return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
            }
        }
        return []
    }

    /// `!cue juno tide`: the first word is the speaker, the rest search what they say.
    static func rankSpeeches(_ items: [SearchItem], text: String, exact: [String]) -> [SearchItem] {
        var words = text.split(separator: " ").map(String.init)
        var items = items
        if let speaker = words.first.map(LinkGraph.key) {
            words.removeFirst()
            items = items.filter { LinkGraph.key($0.fields["cue"] ?? "").hasPrefix(speaker) || LinkGraph.key($0.fields["cue"] ?? "").contains(" " + speaker) }
        }
        let rest = words.map(LinkGraph.key).filter { !$0.isEmpty }
        items = items.filter { item in
            let said = LinkGraph.key(item.keywords.joined(separator: " "))
            return rest.allSatisfy { said.contains($0) } && exact.allSatisfy { said.contains(LinkGraph.key($0)) }
        }
        return items
    }

    static func group(_ items: [SearchItem], limit: Int) -> [SearchSection] {
        var order: [String] = []
        var byGroup: [String: [SearchItem]] = [:]
        for item in items {
            if byGroup[item.group] == nil { order.append(item.group) }
            if byGroup[item.group, default: []].count < limit { byGroup[item.group, default: []].append(item) }
        }
        return order.map { SearchSection(title: $0, items: byGroup[$0] ?? []) }
    }

    /// Bangs whose name starts with what's typed after `!`.
    public static func suggestions(for partial: String, bangs: [Bang]) -> [Bang] {
        let name = Bangs.normalize(partial)
        return bangs.filter { name.isEmpty || $0.name.hasPrefix(name) }
            .sorted { ($0.name == name ? 0 : 1, $0.name.count) < ($1.name == name ? 0 : 1, $1.name.count) }
    }
}

// MARK: - Building items

public enum SearchItems {
    /// A note: its name and aliases, its template's label, tags and every field.
    public static func note(_ note: Note, template: NoteTemplate?) -> SearchItem {
        var fields: [String: String] = [:]
        for field in note.fields where !field.value.text.isEmpty { fields[field.key.lowercased()] = field.value.text }
        if let type = note.type { fields["type"] = type }
        let label = template?.label ?? note.type?.capitalized ?? "Note"
        return SearchItem(
            scope: .template(template?.type ?? note.type ?? "note"),
            group: plural(label, folder: template?.folder),
            title: note.name,
            subtitle: ([label] + note.aliases.prefix(2)).joined(separator: " · "),
            icon: template?.icon ?? "doc.text",
            target: .path(note.path, location: nil),
            tags: Tags.noteTags(note),
            fields: fields,
            keywords: note.aliases,
            id: "note|" + note.path
        )
    }

    static func plural(_ label: String, folder: String?) -> String {
        if label == "Freeform Note" || label == "Note" { return "Notes" }
        if let folder, !folder.isEmpty { return folder.replacingOccurrences(of: "-", with: " ").capitalized }
        return label.hasSuffix("s") ? label : label + "s"
    }

    /// A film's scenes, act files and sections, speeches, and transitions/boneyard notes.
    /// - Parameters:
    ///   - film: The film's title, shown in a saga (nil for a one-film project).
    ///   - filmNumber: 1-based, for `film:2`.
    public static func script(_ book: ScriptBook, film: String?, filmNumber: Int) -> [SearchItem] {
        var items: [SearchItem] = []
        let filmSuffix = film.map { " · " + $0 } ?? ""
        var common: [String: String] = ["filmnumber": String(filmNumber)]
        if let film { common["film"] = film }
        for file in book.files {
            let act = file.parsed
            items.append(SearchItem(scope: .act, group: "Acts", title: file.name, subtitle: (film ?? "") , icon: "doc.text",
                                    target: .path(file.path, location: nil), fields: common, id: "act|" + file.path))
            for line in act.lines where line.kind == .section {
                let title = ScriptEstimate.printedText(of: line)
                guard !title.isEmpty else { continue }
                items.append(SearchItem(scope: .act, group: "Acts", title: title, subtitle: file.name + filmSuffix, icon: "number",
                                        target: .path(file.path, location: line.range.location), fields: common,
                                        id: "section|\(file.path)|\(line.index)"))
            }
        }
        for scene in book.scenes {
            guard let parsed = book.files.first(where: { $0.path == scene.file })?.parsed else { continue }
            let parts = SceneHeading.parse(parsed.lines[scene.scene.headingLine].text).parts
            var fields = common
            let prefix = parts.prefix?.uppercased() ?? ""
            fields["int"] = prefix.hasPrefix("INT") || prefix.contains("/") || prefix.hasPrefix("I/E") ? "yes" : "no"
            fields["ext"] = prefix.hasPrefix("EXT") || prefix.contains("/") || prefix.hasPrefix("I/E") ? "yes" : "no"
            fields["place"] = parts.location
            fields["time"] = parts.time ?? ""
            fields["color"] = scene.scene.color?.rawValue ?? ""
            fields["long"] = scene.eighths > 8 ? "yes" : "no"
            fields["number"] = scene.label
            let target: SearchTarget = scene.scene.sceneID.map(SearchTarget.scene) ?? .path(scene.file, location: parsed.lines[scene.scene.headingLine].range.location)
            items.append(SearchItem(
                scope: .scene, group: "Scenes",
                title: scene.scene.heading.isEmpty ? "Untitled scene" : scene.scene.heading,
                subtitle: "Scene \(scene.label) · \(ScriptEstimate.formatEighths(scene.eighths)) pp" + filmSuffix,
                icon: "film", target: target, tags: scene.scene.tags, fields: fields,
                id: "scene|\(scene.file)|\(scene.scene.id)"
            ))
            // Speeches: the cue, and what's said, opening at the cue.
            var index = scene.scene.lines.lowerBound
            while index < scene.scene.lines.upperBound {
                let line = parsed.lines[index]
                if line.kind == .character, let name = ScriptParser.characterName(fromCue: ScriptEstimate.printedText(of: line)) {
                    var said: [String] = []
                    var next = index + 1
                    while next < scene.scene.lines.upperBound, [.dialogue, .parenthetical, .lyric].contains(parsed.lines[next].kind) {
                        if parsed.lines[next].kind != .parenthetical { said.append(ScriptEstimate.printedText(of: parsed.lines[next])) }
                        next += 1
                    }
                    let text = said.joined(separator: " ")
                    var cueFields = common
                    cueFields["cue"] = name
                    items.append(SearchItem(
                        scope: .cue, group: "Speeches",
                        title: text.isEmpty ? name : String(text.prefix(90)),
                        subtitle: "\(name) · Scene \(scene.label)" + filmSuffix,
                        icon: "text.bubble", target: .path(scene.file, location: line.range.location),
                        tags: scene.scene.tags, fields: cueFields, keywords: [text],
                        id: "cue|\(scene.file)|\(index)"
                    ))
                    index = next
                    continue
                }
                if [.transition, .centered, .boneyard].contains(line.kind) {
                    let text = ScriptEstimate.printedText(of: line).isEmpty ? line.text.trimmingCharacters(in: .whitespaces) : ScriptEstimate.printedText(of: line)
                    if !text.isEmpty {
                        let kind = line.kind == .transition ? "Transition" : line.kind == .centered ? "Centred" : "Boneyard"
                        items.append(SearchItem(scope: .extra, group: "Transitions and Notes", title: String(text.prefix(90)),
                                                subtitle: "\(kind) · Scene \(scene.label)" + filmSuffix, icon: "arrow.turn.down.right",
                                                target: .path(scene.file, location: line.range.location), fields: common,
                                                keywords: [text], id: "extra|\(scene.file)|\(index)"))
                    }
                }
                index += 1
            }
        }
        return items
    }

    /// One item per tag, with what carries it.
    public static func tags(_ index: TagIndex) -> [SearchItem] {
        index.tags.map { tag, count in
            let refs = index.refs[tag] ?? []
            let notes = refs.filter { if case .note = $0 { true } else { false } }.count
            let scenes = refs.count - notes
            var parts: [String] = []
            if notes > 0 { parts.append("\(notes) note" + (notes == 1 ? "" : "s")) }
            if scenes > 0 { parts.append("\(scenes) scene" + (scenes == 1 ? "" : "s")) }
            return SearchItem(scope: .tag, group: "Tags", title: "#" + tag, subtitle: parts.joined(separator: ", "), icon: "number",
                              target: .tag(tag), keywords: [tag], id: "tag|" + tag)
        }
    }
}
