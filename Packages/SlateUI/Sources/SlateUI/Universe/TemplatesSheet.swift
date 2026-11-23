import SlateCore
import SwiftUI

extension ProjectSession {
    var projectTemplatesFolder: URL {
        store.rootURL.appending(path: ProjectLayout.templates, directoryHint: .isDirectory)
    }

    /// Saves a template and reloads the list. Returns false (after showing why) on failure.
    @discardableResult
    func saveTemplate(_ template: NoteTemplate, to location: TemplateLibrary.Location, replacing old: NoteTemplate?) -> Bool {
        do {
            try TemplateLibrary.save(template, to: location, replacing: old,
                                     projectTemplates: projectTemplatesFolder, globalTemplates: Self.globalTemplatesFolder)
            refreshTemplates()
            return true
        } catch {
            SlateAppModel.showError("Couldn't save the “\(template.label)” template", error)
            return false
        }
    }

    /// Deletes any template, built-ins included (see `TemplateLibrary.delete`).
    func deleteTemplate(_ template: NoteTemplate, from location: TemplateLibrary.Location) {
        do {
            try TemplateLibrary.delete(template, from: location, projectTemplates: projectTemplatesFolder, globalTemplates: Self.globalTemplatesFolder)
            refreshTemplates()
        } catch {
            SlateAppModel.showError("Couldn't delete the “\(template.label)” template", error)
        }
    }

    func restoreTemplate(type: String) {
        do {
            try TemplateLibrary.restore(type: type, projectTemplates: projectTemplatesFolder, globalTemplates: Self.globalTemplatesFolder)
            refreshTemplates()
        } catch {
            SlateAppModel.showError("Couldn't restore the template", error)
        }
    }

    /// Notes whose `type:` is `type`.
    func notes(ofType type: String) -> [Note] {
        links.graph.notes.filter { $0.type == type }
    }

    /// Rewrites `type:` in every note of the old type, after a template's type is renamed.
    func retype(notesOf old: String, to new: String) {
        for note in notes(ofType: old) {
            do {
                let document = try store.documents[note.path] ?? store.document(at: note.path)
                let text = Frontmatter.setting("type", to: .string(new), in: document.text)
                if text != document.text {
                    document.text = text
                    store.save(document)
                    links.update(path: note.path, text: text)
                }
            } catch {
                SlateAppModel.showError("Couldn't update \(note.name)", error)
            }
        }
    }

    /// Moves a project or global template to the Trash.
    func removeTemplate(_ template: NoteTemplate) {
        do {
            try TemplateLibrary.remove(template, projectTemplates: projectTemplatesFolder, globalTemplates: Self.globalTemplatesFolder)
            refreshTemplates()
        } catch {
            SlateAppModel.showError("Couldn't remove the “\(template.label)” template", error)
        }
    }
}

/// Universe › Templates…: every template, and a form to edit one.
struct TemplatesSheet: View {
    let session: ProjectSession
    @State private var selection: String?
    /// A new, unsaved template being set up.
    @State private var draft: NoteTemplate?
    @Environment(\.dismiss) private var dismiss

    init(session: ProjectSession, selected: String?) {
        self.session = session
        _selection = State(initialValue: selected ?? session.templates.first?.type)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(session.templates) { template in
                    HStack {
                        Label(template.label, systemImage: template.icon ?? icon(for: template.type))
                        Spacer()
                        Text(badge(template)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(template.type)
                }
                if let draft {
                    Label(draft.label + " (new)", systemImage: "plus.square.dashed").tag("__new__")
                }
                if !session.removedTemplates.isEmpty {
                    Section("Deleted") {
                        ForEach(session.removedTemplates, id: \.type) { removed in
                            HStack {
                                Label(removed.label, systemImage: "trash").foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") {
                                    session.restoreTemplate(type: removed.type)
                                    selection = removed.type
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                            .selectionDisabled()
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(200)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("Blank Template") { startNew(from: nil) }
                        Divider()
                        ForEach(session.templates) { template in
                            Button("Copy of \(template.label)") { startNew(from: template) }
                        }
                    } label: {
                        Label("New Template", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                }
                .padding(8)
            }
        } detail: {
            if selection == "__new__", let draft {
                TemplateEditor(session: session, original: nil, template: draft) { saved in
                    self.draft = nil
                    selection = saved
                }
                .id("new:" + draft.type)
            } else if let selection, let template = session.templates.first(where: { $0.type == selection }) {
                TemplateEditor(session: session, original: template, template: template) { saved in
                    self.selection = saved
                }
                .id(template.type + String(template.origin == .builtIn))
            } else if session.templates.isEmpty {
                ContentUnavailableView {
                    Label("No Templates", systemImage: "square.text.square")
                } description: {
                    Text("Every template has been deleted. Notes you already have keep their fields. Make a new one with + or restore one from Deleted.")
                } actions: {
                    Button("New Template") { startNew(from: nil) }
                }
            } else {
                ContentUnavailableView("No Template Selected", systemImage: "square.text.square")
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .frame(minWidth: 940, minHeight: 620)
    }

    private func badge(_ template: NoteTemplate) -> String {
        switch template.origin {
        case .builtIn: "Built-in"
        case .global: "Every project"
        case .project: "This project"
        }
    }

    private func startNew(from source: NoteTemplate?) {
        let existing = Set(session.templates.map(\.type))
        let label = source.map { "\($0.label) Copy" } ?? "New Type"
        let (type, folder) = TemplateLibrary.newType(label: label, existing: existing)
        var template = source ?? NoteTemplate(type: type, label: label, folder: folder,
                                              fields: [.init(key: "name", type: .text), .init(key: "tags", type: .list)],
                                              body: "## Notes\n", origin: .project)
        template.type = type
        template.label = label
        template.folder = folder
        template.origin = .project
        template.fileName = type + ".md"
        draft = template
        selection = "__new__"
    }
}

/// The form for one template, with a live preview of its infobox.
struct TemplateEditor: View {
    let session: ProjectSession
    /// The template as loaded (nil for a new one).
    let original: NoteTemplate?
    let saved: (String) -> Void

    @State private var template: NoteTemplate
    @State private var placements: [InfoboxLayout.Placement]
    @State private var location: TemplateLibrary.Location
    @State private var confirmingRemove = false
    @State private var confirmingDelete = false

    init(session: ProjectSession, original: NoteTemplate?, template: NoteTemplate, saved: @escaping (String) -> Void) {
        self.session = session
        self.original = original
        self.saved = saved
        _template = State(initialValue: template)
        _placements = State(initialValue: InfoboxLayout.placements(for: template.fields.map(\.key), layout: template.layout))
        _location = State(initialValue: template.origin == .global ? .global : .project)
    }

    /// The template with the placements written back as a layout.
    private var edited: NoteTemplate {
        var copy = template
        copy.layout = InfoboxLayout.layout(from: placements, keeping: template.layout)
        return copy
    }

    private var isDirty: Bool {
        original == nil || edited != original || location != (original?.origin == .global ? .global : .project)
    }

    private var problem: String? {
        let keys = template.fields.map { $0.key.trimmingCharacters(in: .whitespaces) }
        if template.label.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the template a name." }
        if keys.contains(where: \.isEmpty) { return "Every field needs a key." }
        if template.type.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the template a type." }
        if let bang = template.bang {
            let others = session.templates.filter { $0.type != original?.type && $0.type != template.type }
            if others.contains(where: { $0.bang == bang }) { return "Another template already uses !\(bang)." }
        }
        if !template.fields.contains(where: { $0.key == template.nameField }) { return "Pick which field is the note's name." }
        if Set(keys.map { $0.lowercased() }).count != keys.count { return "Two fields have the same key." }
        if let reserved = keys.first(where: { ["type", "id", "layout", "infobox"].contains($0) }) { return "“\(reserved)” is used by Slate; pick another key." }
        if template.folder.trimmingCharacters(in: .whitespaces).isEmpty || template.folder.contains("/") { return "The folder must be one plain folder name." }
        if original == nil || original?.type != template.type,
           session.templates.contains(where: { $0.type == template.type && $0.type != original?.type }) {
            return "Another template already uses the type “\(template.type)”."
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Template") {
                    TextField("Name", text: $template.label)
                    LabeledContent("Icon") {
                        HStack {
                            Image(systemName: template.icon ?? icon(for: template.type)).frame(width: 20)
                            Picker("Icon", selection: Binding(get: { template.icon ?? "" }, set: { template.icon = $0.isEmpty ? nil : $0 })) {
                                Text("Default").tag("")
                                ForEach(Self.icons, id: \.self) { name in
                                    Label(name, systemImage: name).tag(name)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    TextField("Type", text: $template.type, prompt: Text("written as type: in each note"))
                    if let original, original.type != template.type, !session.notes(ofType: original.type).isEmpty {
                        Text("Saving changes type: in the \(session.notes(ofType: original.type).count) notes made from “\(original.label)”.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Folder") {
                        HStack(spacing: 2) {
                            Text("universe/").foregroundStyle(.secondary)
                            TextField("Folder", text: $template.folder).labelsHidden()
                        }
                    }
                    Picker("Name field", selection: $template.nameField) {
                        ForEach(template.fields.filter { $0.type == .text && !$0.key.isEmpty }) { field in
                            Text(field.label.isEmpty ? field.key : "\(field.label) (\(field.key))").tag(field.key)
                        }
                    }
                    .help("The field that names each note (its title in lists and links)")
                    LabeledContent("Search bang") {
                        HStack(spacing: 2) {
                            Text("!").font(.body.monospaced()).foregroundStyle(.secondary)
                            TextField("Bang", text: Binding(get: { template.bang ?? "" },
                                                            set: { template.bang = Bangs.normalize($0).isEmpty ? nil : Bangs.normalize($0) }),
                                      prompt: Text(automaticBang))
                                .font(.body.monospaced())
                                .labelsHidden()
                        }
                    }
                    .help("Type !\(template.bang ?? automaticBang) in Search (⌘K) to search only these notes")
                    Picker("Saved in", selection: $location) {
                        Text("This project").tag(TemplateLibrary.Location.project)
                        Text("Every project").tag(TemplateLibrary.Location.global)
                    }
                }
                Section {
                    // By position, so typing in a key doesn't lose focus.
                    ForEach(template.fields.indices, id: \.self) { index in
                        FieldRow(field: fieldBinding(index), placement: placementBinding(index),
                                 isName: template.fields[index].key == template.nameField, isFirst: index == 0) {
                            remove(at: index)
                        }
                    }
                    .onMove { from, to in
                        template.fields.move(fromOffsets: from, toOffset: to)
                        placements.move(fromOffsets: from, toOffset: to)
                    }
                    Button {
                        var key = "field"
                        var n = 2
                        while template.fields.contains(where: { $0.key == key }) { key = "field\(n)"; n += 1 }
                        template.fields.append(.init(key: key, type: .text))
                        placements.append(.init(key: key))
                    } label: {
                        Label("Add Field", systemImage: "plus")
                    }
                } header: {
                    Text("Fields")
                } footer: {
                    Text("Drag to reorder. “Section” puts a header above the field; “Beside previous” shows it in a column next to the field above. Existing notes keep their values; renamed keys show as extra fields.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Starter headings") {
                    TextEditor(text: $template.body)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                }
                if let problem {
                    Text(problem).foregroundStyle(.orange)
                }
                HStack {
                    if let original {
                        Button("Delete Template", role: .destructive) { confirmingDelete = true }
                        if original.origin != .builtIn, TemplateLibrary.hasBuiltIn(original.type) {
                            Button("Revert to Built-in") { confirmingRemove = true }
                        }
                    }
                    Spacer()
                    if original != nil {
                        Button("Discard Changes") { reset() }.disabled(!isDirty)
                    }
                    Button("Save") { save() }
                        .keyboardShortcut("s")
                        .disabled(problem != nil || !isDirty)
                }
                .confirmationDialog("Revert “\(template.label)” to Slate's built-in template?", isPresented: $confirmingRemove) {
                    Button("Revert", role: .destructive) {
                        if let original { session.removeTemplate(original) }
                        saved(original?.type ?? "")
                    }
                } message: {
                    Text("Your version goes to the Trash. Notes already made from it keep their fields.")
                }
                .confirmationDialog("Delete the “\(template.label)” template?", isPresented: $confirmingDelete) {
                    Button(deleteScope == .global ? "Delete from Every Project" : "Delete", role: .destructive) {
                        if let original { session.deleteTemplate(original, from: deleteScope) }
                        saved(session.templates.first?.type ?? "")
                    }
                } message: {
                    Text(deleteMessage)
                }
                if original?.origin == .builtIn {
                    Text("This is one of Slate's starting templates. Change or delete it like any other: your version is saved in \(location == .global ? "the templates folder for every project" : "this project's templates/ folder"), and Revert to Built-in brings Slate's back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 460)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview").font(.headline)
                ScrollView {
                    InfoboxCard(content: .sample(for: edited))
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                    if !template.body.isEmpty {
                        Text(LinkURL.attributed(template.body))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(16)
            .frame(width: 300)
        }
        .navigationTitle(template.label)
    }

    /// The bang Search gives this template when it has none of its own.
    private var automaticBang: String {
        var others = session.templates.filter { $0.type != original?.type && $0.type != template.type }
        var copy = template
        copy.bang = nil
        others.append(copy)
        return Bangs.all(templates: others, renames: SearchPreferences.renames).first { $0.scope == .template(template.type) }?.name ?? ""
    }

    /// Where a delete applies: a built-in follows "Saved in"; others where their file is.
    private var deleteScope: TemplateLibrary.Location {
        switch original?.origin {
        case .global: .global
        case .builtIn: location
        default: .project
        }
    }

    private var deleteMessage: String {
        let count = original.map { session.notes(ofType: $0.type).count } ?? 0
        let notes = count == 0 ? "No notes use it." : "The \(count) notes made from it stay, with all their fields."
        let scope = deleteScope == .global ? "It's removed from every project." : "It's removed from this project only."
        return "\(scope) \(notes) Deleted templates can be restored from the list's Deleted section."
    }

    private func fieldBinding(_ index: Int) -> Binding<NoteTemplate.Field> {
        Binding(
            get: { template.fields.indices.contains(index) ? template.fields[index] : .init(key: "", type: .text) },
            set: { field in
                guard template.fields.indices.contains(index) else { return }
                // Renaming the name field's key keeps it the name.
                if template.fields[index].key == template.nameField, field.key != template.nameField { template.nameField = field.key }
                template.fields[index] = field
            }
        )
    }

    private func placementBinding(_ index: Int) -> Binding<InfoboxLayout.Placement> {
        Binding(
            get: { placements.indices.contains(index) ? placements[index] : .init(key: "") },
            set: { if placements.indices.contains(index) { placements[index] = $0 } }
        )
    }

    private func remove(at index: Int) {
        guard template.fields.indices.contains(index) else { return }
        let key = template.fields[index].key
        template.fields.remove(at: index)
        if placements.indices.contains(index) { placements.remove(at: index) }
        // Removing the name field hands the name to the next text field.
        if key == template.nameField, let next = template.fields.first(where: { $0.type == .text }) {
            template.nameField = next.key
        }
    }

    private func reset() {
        guard let original else { return }
        template = original
        placements = InfoboxLayout.placements(for: original.fields.map(\.key), layout: original.layout)
        location = original.origin == .global ? .global : .project
    }

    private func save() {
        var result = edited
        result.type = result.type.trimmingCharacters(in: .whitespaces)
        result.label = result.label.trimmingCharacters(in: .whitespaces)
        result.folder = result.folder.trimmingCharacters(in: .whitespaces)
        for index in result.fields.indices {
            result.fields[index].key = result.fields[index].key.trimmingCharacters(in: .whitespaces)
        }
        // A built-in is never replaced on disk: saving makes an override.
        let replacing = original?.origin == .builtIn ? nil : original
        if session.saveTemplate(result, to: location, replacing: replacing) {
            if let original, original.type != result.type { session.retype(notesOf: original.type, to: result.type) }
            saved(result.type)
        }
    }

    static let icons = [
        "person.fill", "person.2.fill", "figure.walk", "pawprint.fill", "mappin.and.ellipse", "building.2.fill",
        "house.fill", "globe.americas.fill", "scroll.fill", "book.closed.fill", "key.fill", "wand.and.stars",
        "bolt.fill", "flame.fill", "shield.fill", "crown.fill", "flag.fill", "clock.fill", "calendar",
        "car.fill", "airplane", "sailboat.fill", "cube.fill", "sparkles", "atom", "leaf.fill", "star.fill",
    ]
}

/// One field: key, label, type, options, and where the infobox puts it.
private struct FieldRow: View {
    @Binding var field: NoteTemplate.Field
    @Binding var placement: InfoboxLayout.Placement
    let isName: Bool
    let isFirst: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                TextField("key", text: Binding(get: { field.key }, set: { new in
                    let defaultLabel = field.label == NoteTemplate.Field.defaultLabel(for: field.key)
                    field.key = new
                    placement.key = new
                    if defaultLabel { field.label = NoteTemplate.Field.defaultLabel(for: new) }
                }))
                .font(.system(.body, design: .monospaced))
                .frame(width: 130)
                TextField("Label", text: $field.label)
                Picker("Type", selection: $field.type) {
                    ForEach(NoteTemplate.FieldType.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help(isName ? "Remove this field (the next text field becomes the name)" : "Remove this field")
            }
            if field.type == .choice {
                TextField("Options, separated by commas", text: Binding(
                    get: { field.options.joined(separator: ", ") },
                    set: { field.options = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ))
                .font(.callout)
            }
            if !isName {
                HStack {
                    TextField("Section (optional)", text: Binding(get: { placement.section ?? "" }, set: { placement.section = $0.isEmpty ? nil : $0 }))
                        .font(.callout)
                    Toggle("Beside previous", isOn: $placement.besidePrevious)
                        .toggleStyle(.checkbox)
                        .disabled(isFirst)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension ProjectSession {
    /// Makes `universe/canvases/untitled.canvas` (numbered if taken) and opens it.
    func createCanvas() {
        let existing = Set(allPaths.map { $0.lowercased() })
        var path = "universe/canvases/untitled.canvas"
        var counter = 2
        while existing.contains(path) {
            path = "universe/canvases/untitled-\(counter).canvas"
            counter += 1
        }
        do {
            try store.createTextFile(at: path, contents: CanvasFile.empty)
            open(path)
        } catch {
            SlateAppModel.showError("Couldn't create the canvas", error)
        }
    }
}
