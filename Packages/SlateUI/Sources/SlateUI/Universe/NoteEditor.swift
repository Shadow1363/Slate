import AppKit
import SlateCore
import SwiftUI

/// A templated note: a form of its fields above the Markdown body. Both
/// write the same file; the form changes only the lines of the field edited.
struct NoteEditor: View {
    let session: ProjectSession
    @Bindable var document: TextDocument
    @Environment(\.slateTheme) private var theme
    @AppStorage("noteFieldsExpanded") private var fieldsExpanded = true

    var body: some View {
        let note = Note(path: document.relativePath, text: document.text)
        VStack(spacing: 0) {
            DiskStateBanners(store: session.store, document: document, close: { session.universeSelection = nil })
            if let error = note.frontmatterError {
                Banner(systemImage: "exclamationmark.triangle.fill", message: "\(error). Fix it below; the form returns when the YAML is valid.") {}
                MarkdownEditor(document: document, text: document.text, hidesFrontmatter: false, theme: theme,
                               reveal: session.noteReveal, linkVersion: session.links.version, session: session,
                           spelling: session.noteSpelling)
            } else {
                NoteHeader(session: session, document: document, note: note, expanded: $fieldsExpanded)
                Divider()
                MarkdownEditor(document: document, text: document.text, hidesFrontmatter: true, theme: theme,
                               reveal: session.noteReveal, linkVersion: session.links.version, session: session,
                           spelling: session.noteSpelling)
            }
            Divider()
            FileStatusBar(document: document)
        }
        .navigationTitle(note.name)
    }
}

/// The note's name, type and fields.
private struct NoteHeader: View {
    let session: ProjectSession
    let document: TextDocument
    let note: Note
    @Binding var expanded: Bool
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var template: NoteTemplate? { session.template(for: note.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon(for: note.type)).foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .help("Press Return to rename; Slate offers to update links.")
                Text(template?.label ?? note.type?.capitalized ?? "Note")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Hide fields" : "Show fields")
            }
            if expanded {
                NoteFields(session: session, document: document, note: note, template: template)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onAppear {
            name = note.name
            if session.focusNameField == document.relativePath {
                session.focusNameField = nil
                nameFocused = true
            }
        }
        .onChange(of: note.name) { _, new in if !nameFocused { name = new } }
        .onChange(of: nameFocused) { _, focused in if !focused { name = note.name } }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != note.name else {
            name = note.name
            return
        }
        session.sheet = .rename(document.relativePath, trimmed)
    }
}

/// One row per template field, then any other keys in the file.
private struct NoteFields: View {
    let session: ProjectSession
    let document: TextDocument
    let note: Note
    let template: NoteTemplate?

    private static let hidden: Set<String> = ["type", "id", "name"]

    var body: some View {
        let declared = (template?.fields ?? []).filter { !Self.hidden.contains($0.key) }
        let keys = Set(declared.map(\.key))
        let extras = note.fields.filter { !keys.contains($0.key) && !Self.hidden.contains($0.key) }
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(declared) { field in
                GridRow {
                    Text(field.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    FieldEditor(session: session, document: document, key: field.key, type: field.type, value: note.value(field.key) ?? .null)
                }
            }
            ForEach(extras, id: \.key) { field in
                GridRow {
                    Text(field.key).foregroundStyle(.secondary).italic().help("Not in the \(template?.label ?? "note") template")
                    FieldEditor(session: session, document: document, key: field.key, type: guessType(field.value), value: field.value)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func guessType(_ value: YAMLValue) -> NoteTemplate.FieldType {
        switch value {
        case .list: .list
        case .int, .double: .number
        default: .text
        }
    }
}

/// Edits one frontmatter key in place.
private struct FieldEditor: View {
    let session: ProjectSession
    let document: TextDocument
    let key: String
    let type: NoteTemplate.FieldType
    let value: YAMLValue

    var body: some View {
        switch type {
        case .text:
            TextField(key, text: Binding(get: { value.text }, set: { set($0.isEmpty ? .null : .string($0)) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
        case .number:
            TextField(key, text: Binding(get: { value.text }, set: { set(number($0)) }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
        case .date:
            DateField(value: value.text) { set($0.map(YAMLValue.string) ?? .null) }
        case .list:
            ListField(items: value.items) { set(.list($0.map(YAMLValue.string))) }
        case .link:
            LinkField(session: session, target: value.text.isEmpty ? "" : WikiLink.target(inFieldValue: value.text)) { target in
                set(target.isEmpty ? .null : .string(WikiLink.text(for: target)))
            }
        case .image:
            ImageField(session: session, document: document, key: key, value: value.text) { set($0.map(YAMLValue.string) ?? .null) }
        }
    }

    private func set(_ newValue: YAMLValue) {
        let updated = Frontmatter.setting(key, to: newValue, in: document.text)
        if updated != document.text { document.text = updated }
    }

    private func number(_ text: String) -> YAMLValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .null }
        if let int = Int(trimmed) { return .int(int) }
        if let double = Double(trimmed) { return .double(double) }
        return .string(trimmed)
    }
}

/// `YYYY-MM-DD`, with a calendar picker; other text is kept as typed.
private struct DateField: View {
    let value: String
    let set: (String?) -> Void

    private static let format: Date.ISO8601FormatStyle = .iso8601.year().month().day()

    var body: some View {
        HStack {
            if let date = try? Self.format.parse(value) {
                DatePicker("", selection: Binding(get: { date }, set: { set($0.formatted(Self.format)) }), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                Button { set(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear the date")
            } else if !value.isEmpty {
                TextField("YYYY-MM-DD", text: Binding(get: { value }, set: { set($0.isEmpty ? nil : $0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
            } else {
                Button("Add Date") { set(Date().formatted(Self.format)) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Tokens with a remove button, plus a field to add one.
private struct ListField: View {
    let items: [String]
    let set: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 3) {
                    Text(item).lineLimit(1)
                    Button {
                        var copy = items
                        copy.remove(at: index)
                        set(copy)
                    } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(item)")
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
            }
            TextField("Add…", text: $draft)
                .textFieldStyle(.plain)
                .frame(minWidth: 80)
                .onSubmit {
                    let new = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard !new.isEmpty else { return }
                    set(items + new)
                    draft = ""
                }
            Spacer(minLength: 0)
        }
    }
}

/// A note name, stored as `"[[Name]]"`, with suggestions while typing.
private struct LinkField: View {
    let session: ProjectSession
    let target: String
    let set: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let graph = session.links.graph
        let suggestions = focused && !draft.isEmpty ? graph.completions(prefix: draft, limit: 5).filter { $0.text != draft } : []
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Note name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { set(draft.trimmingCharacters(in: .whitespaces)) }
                if !target.isEmpty {
                    let resolved = graph.resolve(target) != nil
                    Button {
                        session.followLink(target)
                    } label: {
                        Image(systemName: resolved ? "arrow.right.circle" : "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(resolved ? "Open \(target)" : "\(target) doesn't exist yet. Create it…")
                }
            }
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions) { item in
                        Button(item.text) {
                            draft = item.text
                            set(item.text)
                            focused = false
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
        .onAppear { draft = target }
        .onChange(of: target) { _, new in if !focused { draft = new } }
        .onChange(of: focused) { _, isFocused in
            if !isFocused, draft.trimmingCharacters(in: .whitespaces) != target { set(draft.trimmingCharacters(in: .whitespaces)) }
        }
    }
}

/// An image beside the note, stored as a path relative to the note.
private struct ImageField: View {
    let session: ProjectSession
    let document: TextDocument
    let key: String
    let value: String
    let set: (String?) -> Void

    private var folder: String { (document.relativePath as NSString).deletingLastPathComponent }

    var body: some View {
        HStack(spacing: 10) {
            if !value.isEmpty, let url = try? session.store.url(for: folder + "/" + value), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 6))
                    .help(value)
            } else if !value.isEmpty {
                Label(value, systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            }
            Button(value.isEmpty ? "Choose Image…" : "Replace…", action: choose)
            if !value.isEmpty {
                Button("Remove") { set(nil) }.buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
    }

    /// Copies the chosen image next to the note: `<note>-<field>.<ext>`.
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let stem = ((document.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = "\(stem)-\(Slug.make(key)).\(source.pathExtension.lowercased())"
        do {
            let data = try Data(contentsOf: source)
            try CoordinatedFileIO.write(data, to: try session.store.url(for: folder + "/" + name))
            session.store.rescan()
            set(name)
        } catch {
            SlateAppModel.showError("Couldn't copy the image", error)
        }
    }
}
