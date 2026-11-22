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
        original == nil || edited != original || location != (original?.origin == .global ? .global : .project) || original?.origin == .builtIn
    }

    private var problem: String? {
        let keys = template.fields.map { $0.key.trimmingCharacters(in: .whitespaces) }
        if template.label.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the template a name." }
        if keys.contains(where: \.isEmpty) { return "Every field needs a key." }
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
                        .disabled(original != nil && original?.origin != .builtIn && session.links.graph.notes.contains { $0.type == original?.type })
                    LabeledContent("Folder") {
                        HStack(spacing: 2) {
                            Text("universe/").foregroundStyle(.secondary)
                            TextField("Folder", text: $template.folder).labelsHidden()
                        }
                    }
                    Picker("Name field", selection: $template.nameField) {
                        Text("name").tag("name")
                        Text("title").tag("title")
                    }
                    .onChange(of: template.nameField) { old, new in renameNameField(from: old, to: new) }
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
                    if let original, original.origin != .builtIn {
                        if TemplateLibrary.hasBuiltIn(original.type) {
                            Button("Revert to Built-in") { confirmingRemove = true }
                        } else {
                            Button("Delete Template", role: .destructive) { confirmingRemove = true }
                        }
                    }
                    Spacer()
                    if original != nil {
                        Button("Discard Changes") { reset() }.disabled(!isDirty || original?.origin == .builtIn)
                    }
                    Button(original?.origin == .builtIn ? "Save a Copy" : "Save") { save() }
                        .keyboardShortcut("s")
                        .disabled(problem != nil || !isDirty)
                }
                .confirmationDialog(confirmTitle, isPresented: $confirmingRemove) {
                    Button(TemplateLibrary.hasBuiltIn(original?.type ?? "") ? "Revert" : "Move to Trash", role: .destructive) {
                        if let original { session.removeTemplate(original) }
                        saved(original?.type ?? "")
                    }
                } message: {
                    Text("Notes already made from it keep their fields. The file goes to the Trash.")
                }
                if original?.origin == .builtIn {
                    Text("Built-in templates can't be changed. Saving makes your own copy, which replaces the built-in.")
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

    private var confirmTitle: String {
        TemplateLibrary.hasBuiltIn(original?.type ?? "") ? "Revert “\(template.label)” to the built-in template?" : "Delete the “\(template.label)” template?"
    }

    private func fieldBinding(_ index: Int) -> Binding<NoteTemplate.Field> {
        Binding(
            get: { template.fields.indices.contains(index) ? template.fields[index] : .init(key: "", type: .text) },
            set: { if template.fields.indices.contains(index) { template.fields[index] = $0 } }
        )
    }

    private func placementBinding(_ index: Int) -> Binding<InfoboxLayout.Placement> {
        Binding(
            get: { placements.indices.contains(index) ? placements[index] : .init(key: "") },
            set: { if placements.indices.contains(index) { placements[index] = $0 } }
        )
    }

    private func remove(at index: Int) {
        guard template.fields.indices.contains(index), template.fields[index].key != template.nameField else { return }
        template.fields.remove(at: index)
        if placements.indices.contains(index) { placements.remove(at: index) }
    }

    /// Switching between `name` and `title` renames that field.
    private func renameNameField(from old: String, to new: String) {
        if let index = template.fields.firstIndex(where: { $0.key == old }) {
            template.fields[index].key = new
            template.fields[index].label = NoteTemplate.Field.defaultLabel(for: new)
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
                .disabled(isName)
                TextField("Label", text: $field.label)
                Picker("Type", selection: $field.type) {
                    ForEach(NoteTemplate.FieldType.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                .disabled(isName)
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(isName)
                    .help(isName ? "Every note needs its name field" : "Remove this field")
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
