import AppKit
import SlateCore
import SwiftUI

/// What an infobox shows: a note's (or a sample's) name, subtitle, picture
/// and fields, arranged by its layout.
struct InfoboxContent {
    var name: String
    var subtitle: String?
    var typeLabel: String
    var icon: String
    /// The picture, already resolved to a file.
    var image: URL?
    var imageKey: String?
    var rows: [InfoboxLayout.Row]
    var values: [String: YAMLValue]
    var fields: [String: NoteTemplate.Field]

    func label(for key: String) -> String {
        fields[key]?.label ?? NoteTemplate.Field.defaultLabel(for: key)
    }

    func type(for key: String) -> NoteTemplate.FieldType {
        fields[key]?.type ?? InfoboxContent.guessType(values[key] ?? .null)
    }

    func value(_ key: String) -> YAMLValue { values[key] ?? .null }

    /// Every key in row order (columns flattened).
    var keys: [String] {
        rows.flatMap { row -> [String] in
            switch row {
            case .header: []
            case .field(let key): [key]
            case .columns(let keys): keys
            }
        }
    }

    static func guessType(_ value: YAMLValue) -> NoteTemplate.FieldType {
        switch value {
        case .list(let items):
            items.contains { !WikiLink.find(in: $0.text).isEmpty } ? .links : .list
        case .int, .double: .number
        case .bool: .bool
        case .string(let text):
            if text.contains("\n") { .longText } else if WikiLink.find(in: text).count == 1, text.hasPrefix("[[") { .link } else { .text }
        default: .text
        }
    }

    /// The infobox for a note in a project.
    @MainActor
    static func make(note: Note, template: NoteTemplate?, store: ProjectStore) -> InfoboxContent {
        let noteLayout = InfoboxLayout.parse(note.value("layout"))
        let layout = noteLayout.isEmpty ? (template?.layout ?? []) : noteLayout
        let templateFields = template?.fields ?? []
        let nameField = template?.nameField ?? "name"
        let noteKeys = note.fields.map(\.key)
        let imageKey = InfoboxLayout.imageKey(layout: layout, fields: templateFields, noteKeys: noteKeys)
        var excluded = InfoboxLayout.structuralKeys
        excluded.insert(nameField)
        if let imageKey { excluded.insert(imageKey) }
        let rows = InfoboxLayout.rows(templateKeys: templateFields.map(\.key), noteKeys: noteKeys, layout: layout, excluding: excluded)
        var values: [String: YAMLValue] = [:]
        for field in note.fields { values[field.key] = field.value }
        var image: URL?
        if let imageKey, let path = note.value(imageKey)?.text, !path.isEmpty {
            let folder = (note.path as NSString).deletingLastPathComponent
            for candidate in [folder + "/" + path, path] {
                if let url = try? store.url(for: candidate), FileManager.default.fileExists(atPath: url.path) {
                    image = url
                    break
                }
            }
        }
        return InfoboxContent(
            name: note.name, subtitle: note.subtitle,
            typeLabel: template?.label ?? note.type?.capitalized ?? "Note",
            icon: template?.icon ?? iconName(for: note.type),
            image: image, imageKey: imageKey, rows: rows, values: values,
            fields: Dictionary(templateFields.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        )
    }

    /// A made-up note for a template's live preview.
    static func sample(for template: NoteTemplate) -> InfoboxContent {
        var values: [String: YAMLValue] = [:]
        for field in template.fields where field.key != template.nameField {
            values[field.key] = switch field.type {
            case .text: .string("Some \(field.label.lowercased())")
            case .longText: .string("A longer paragraph about \(field.label.lowercased()).")
            case .number: .int(34)
            case .date: .string("2031-03-14")
            case .choice: field.options.first.map(YAMLValue.string) ?? .string("Option")
            case .bool: .bool(true)
            case .list: .list([.string("One"), .string("Two")])
            case .link: .string("[[A Note]]")
            case .links: .list([.string("[[First]]"), .string("[[Second]]")])
            case .image: .null
            }
        }
        let imageKey = InfoboxLayout.imageKey(layout: template.layout, fields: template.fields, noteKeys: [])
        var excluded = InfoboxLayout.structuralKeys
        excluded.insert(template.nameField)
        if let imageKey { excluded.insert(imageKey) }
        return InfoboxContent(
            name: "Sample \(template.label)", subtitle: nil, typeLabel: template.label,
            icon: template.icon ?? iconName(for: template.type), image: nil, imageKey: imageKey,
            rows: InfoboxLayout.rows(templateKeys: template.fields.map(\.key), noteKeys: [], layout: template.layout, excluding: excluded),
            values: values, fields: Dictionary(template.fields.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        )
    }
}

/// The wiki-style card: name, subtitle, picture, then rows, headers and
/// columns. Empty fields are left out until you edit.
struct InfoboxCard: View {
    let content: InfoboxContent
    var compact = false
    @Environment(\.slateTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            VStack(spacing: 2) {
                Text(content.name)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let subtitle = content.subtitle {
                    SpoilerText(text: subtitle).font(.callout.italic()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 6))
            if let url = content.image, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: compact ? 120 : 260)
                    .clipShape(.rect(cornerRadius: 6))
            }
            if content.visibleRows.isEmpty, !compact {
                Text("No details yet.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            InfoboxRows(content: content, compact: compact)
        }
        .font(compact ? .caption : .callout)
    }
}

/// The rows of an infobox, empty fields left out.
struct InfoboxRows: View {
    let content: InfoboxContent
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            ForEach(Array(content.visibleRows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .header(let text):
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: .rect(cornerRadius: 4))
                case .field(let key):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(content.label(for: key))
                            .fontWeight(.medium)
                            .foregroundStyle(compact ? .secondary : .primary)
                            .frame(width: compact ? 70 : 92, alignment: .leading)
                        InfoboxValue(value: content.value(key), type: content.type(for: key))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .columns(let keys):
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(keys, id: \.self) { key in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(content.label(for: key)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                InfoboxValue(value: content.value(key), type: content.type(for: key))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .font(compact ? .caption : .callout)
    }
}

extension InfoboxContent {
    /// The first `count` visible rows (all when nil), for small previews.
    func limited(to count: Int?) -> InfoboxContent {
        guard let count else { return self }
        var copy = self
        copy.rows = Array(visibleRows.prefix(count))
        return copy
    }

    /// Rows with something to show; headers only when something follows them.
    var visibleRows: [InfoboxLayout.Row] {
        var result: [InfoboxLayout.Row] = []
        var pendingHeaders: [InfoboxLayout.Row] = []
        for row in rows {
            switch row {
            case .header:
                pendingHeaders.append(row)
            case .field(let key):
                guard !value(key).isEmpty else { continue }
                result += pendingHeaders
                pendingHeaders = []
                result.append(row)
            case .columns(let keys):
                let present = keys.filter { !value($0).isEmpty }
                guard !present.isEmpty else { continue }
                result += pendingHeaders
                pendingHeaders = []
                result.append(present.count == 1 ? .field(present[0]) : .columns(present))
            }
        }
        return result
    }
}

/// One value: links clickable, lists one per line, spoilers hidden.
struct InfoboxValue: View {
    let value: YAMLValue
    let type: NoteTemplate.FieldType

    var body: some View {
        switch value {
        case .list(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    SpoilerText(text: item.text)
                }
            }
        case .bool(let flag):
            Text(flag ? "Yes" : "No")
        default:
            SpoilerText(text: value.text)
        }
    }
}

/// Inline Markdown with clickable `[[links]]`; `||spoilers||` are blacked
/// out until clicked.
struct SpoilerText: View {
    let text: String
    @State private var revealed = false

    var body: some View {
        let pieces = Spoiler.pieces(text)
        if pieces.contains(where: \.isSpoiler) {
            pieces.reduce(Text("")) { result, piece in
                if piece.isSpoiler, !revealed {
                    // Solid blocks, one per letter, so the length hints and nothing more.
                    return result + Text(String(repeating: "█", count: max(piece.text.count, 3))).foregroundStyle(Color.primary.opacity(0.85))
                }
                return result + Text(LinkURL.attributed(piece.text))
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { revealed.toggle() } }
            .help(revealed ? "Click to hide" : "Spoiler: click to reveal")
            .accessibilityLabel(revealed ? pieces.map(\.text).joined() : "Spoiler, hidden")
            .accessibilityAddTraits(.isButton)
        } else {
            Text(LinkURL.attributed(text)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The infobox in edit mode: one control per field, in row order, plus
/// an Add Field menu for keys the template doesn't have yet.
struct InfoboxEditor: View {
    let session: ProjectSession
    let document: TextDocument
    let content: InfoboxContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imageKey = content.imageKey {
                VStack(alignment: .leading, spacing: 3) {
                    Text(content.label(for: imageKey)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    FieldEditor(session: session, document: document, key: imageKey, type: .image, field: content.fields[imageKey],
                                value: content.value(imageKey))
                }
            }
            ForEach(content.rows.indices, id: \.self) { index in
                switch content.rows[index] {
                case .header(let text):
                    Text(text).font(.subheadline.weight(.semibold)).padding(.top, 4)
                case .field(let key):
                    row(key)
                case .columns(let keys):
                    ForEach(keys, id: \.self) { row($0) }
                }
            }
        }
        .font(.callout)
    }

    private func row(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(content.label(for: key))
                .font(.caption.weight(.medium))
                .foregroundStyle(content.fields[key] == nil ? .tertiary : .secondary)
                .help(content.fields[key] == nil ? "Not in the \(content.typeLabel) template" : "")
            FieldEditor(session: session, document: document, key: key, type: content.type(for: key), field: content.fields[key],
                        value: content.value(key))
        }
    }
}

func iconName(for type: String?) -> String {
    icon(for: type)
}
