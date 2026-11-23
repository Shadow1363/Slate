import AppKit
import SlateCore
import SwiftUI

/// A templated note as a wiki page: the Markdown body on the left and the
/// infobox card on the right. Both write the same file; editing the
/// infobox changes only the lines of the field edited.
struct NoteEditor: View {
    let session: ProjectSession
    @Bindable var document: TextDocument
    @Environment(\.slateTheme) private var theme
    @AppStorage("noteInfoboxShown") private var infoboxShown = true
    @State private var editingInfobox = false

    var body: some View {
        let note = Note(path: document.relativePath, text: document.text)
        VStack(spacing: 0) {
            DiskStateBanners(store: session.store, document: document, close: { session.universeSelection = nil })
            if let error = note.frontmatterError {
                Banner(systemImage: "exclamationmark.triangle.fill", message: "\(error). Fix it below; the infobox returns when the YAML is valid.") {}
                MarkdownEditor(document: document, text: document.text, hidesFrontmatter: false, theme: theme,
                               reveal: session.noteReveal, linkVersion: session.links.version, session: session,
                               spelling: session.noteSpelling)
            } else {
                let template = session.template(for: note.type)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        NoteHeader(session: session, document: document, note: note, template: template,
                                   infoboxShown: $infoboxShown)
                        NoteTagStrip(session: session, note: note)
                        Divider()
                        MarkdownEditor(document: document, text: document.text, hidesFrontmatter: true, theme: theme,
                                       reveal: session.noteReveal, linkVersion: session.links.version, session: session,
                                       spelling: session.noteSpelling)
                    }
                    if infoboxShown {
                        Divider()
                        InfoboxPane(session: session, document: document, note: note, template: template, editing: $editingInfobox)
                            .frame(width: 300)
                    }
                }
            }
            Divider()
            FileStatusBar(document: document)
        }
        .navigationTitle(note.name)
    }
}

/// The right-hand infobox, with Edit / Done.
private struct InfoboxPane: View {
    let session: ProjectSession
    let document: TextDocument
    let note: Note
    let template: NoteTemplate?
    @Binding var editing: Bool

    var body: some View {
        let content = InfoboxContent.make(note: note, template: template, store: session.store)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if editing {
                    InfoboxEditor(session: session, document: document, content: content)
                    AddFieldMenu(session: session, document: document, note: note, template: template)
                } else {
                    InfoboxCard(content: content)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = true }
                }
            }
            .padding(14)
        }
        .environment(\.openURL, linkAction(session))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(content.typeLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(editing ? "Done" : "Edit") { withAnimation(.snappy) { editing.toggle() } }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

/// Adds a key that isn't in the note yet: a template field, or a new one.
private struct AddFieldMenu: View {
    let session: ProjectSession
    let document: TextDocument
    let note: Note
    let template: NoteTemplate?
    @State private var newKey = ""

    var body: some View {
        HStack {
            TextField("New field", text: $newKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add", action: add).disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .font(.callout)
        .help("Adds a key to this note only. To add it to every new note, edit the template (Universe › Templates…).")
    }

    private func add() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, note.value(key) == nil else { return }
        // `.null` writes a bare `key:`, ready to fill in.
        document.text = Frontmatter.setting(key, to: .null, in: document.text)
        newKey = ""
    }
}

/// The note's name and type, above the body.
private struct NoteHeader: View {
    let session: ProjectSession
    let document: TextDocument
    let note: Note
    let template: NoteTemplate?
    @Binding var infoboxShown: Bool
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: template?.icon ?? icon(for: note.type)).foregroundStyle(.secondary)
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
                withAnimation(.snappy) { infoboxShown.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(infoboxShown ? "Hide the infobox" : "Show the infobox")
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

/// Edits one frontmatter key in place.
struct FieldEditor: View {
    let session: ProjectSession
    let document: TextDocument
    let key: String
    let type: NoteTemplate.FieldType
    let field: NoteTemplate.Field?
    let value: YAMLValue

    var body: some View {
        switch type {
        case .text:
            TextField(key, text: Binding(get: { value.text }, set: { set($0.isEmpty ? .null : .string($0)) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
        case .longText:
            TextField(key, text: Binding(get: { value.text }, set: { set($0.isEmpty ? .null : .string($0)) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...12)
        case .number:
            TextField(key, text: Binding(get: { value.text }, set: { set(number($0)) }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
        case .date:
            DateField(value: value.text) { set($0.map(YAMLValue.string) ?? .null) }
        case .choice:
            let options = field?.options ?? []
            Picker(key, selection: Binding(get: { value.text }, set: { set($0.isEmpty ? .null : .string($0)) })) {
                Text("None").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
                if !value.text.isEmpty, !options.contains(value.text) {
                    Text(value.text).tag(value.text)
                }
            }
            .labelsHidden()
        case .bool:
            Toggle(field?.label ?? key, isOn: Binding(get: { value == .bool(true) || value.text.lowercased() == "yes" }, set: { set(.bool($0)) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
        case .list:
            ListField(items: value.items) { set(.list($0.map(YAMLValue.string))) }
        case .link:
            LinkField(session: session, target: value.text.isEmpty ? "" : WikiLink.target(inFieldValue: value.text)) { target in
                set(target.isEmpty ? .null : .string(WikiLink.text(for: target)))
            }
        case .links:
            LinksField(session: session, items: value.items) { set(.list($0.map(YAMLValue.string))) }
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

/// Several `[[links]]`: chips showing each link's text, and a field with
/// suggestions to add one. Hand-written items (with `#heading|alias`) are kept.
private struct LinksField: View {
    let session: ProjectSession
    let items: [String]
    let set: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        let suggestions = draft.isEmpty ? [] : session.links.graph.completions(prefix: draft, limit: 4)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 4) {
                    Text(LinkURL.attributed(item)).lineLimit(1)
                    Spacer(minLength: 0)
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
            }
            TextField("Add a link…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add(draft) }
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions) { item in
                        Button(item.text) { add(item.text) }.buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
        .environment(\.openURL, linkAction(session))
    }

    private func add(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        set(items + [name.hasPrefix("[[") ? name : WikiLink.text(for: name)])
        draft = ""
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
