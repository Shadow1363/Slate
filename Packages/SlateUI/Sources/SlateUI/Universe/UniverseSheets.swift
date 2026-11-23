import AppKit
import SlateCore
import SwiftUI

// MARK: - Inspector

/// ⌥⌘0: backlinks to the open note, where a character appears, and links
/// in this file that don't resolve.
struct LinksInspector: View {
    let session: ProjectSession
    @Environment(\.slateTheme) private var theme

    var body: some View {
        let graph = session.links.graph
        Group {
            if let path = currentPath {
                let note = graph.note(at: path)
                List {
                    let backlinks = graph.backlinks(to: path)
                    Section("Backlinks") {
                        if note == nil {
                            Text("Only notes have backlinks.").foregroundStyle(.secondary)
                        } else if backlinks.isEmpty {
                            Text("Nothing links here yet.").foregroundStyle(.secondary)
                        }
                        ForEach(backlinks) { source in
                            BacklinkRow(source: source, graph: graph)
                                .contentShape(Rectangle())
                                .onTapGesture { open(source) }
                        }
                    }
                    if let note, note.type == "character" {
                        let scenes = Set(backlinks.compactMap(\.sceneID))
                        let appearances = CharacterAppearances(names: [note.name] + note.aliases, book: session.script.book, linkedScenes: scenes)
                        Section("In the Script") {
                            if appearances.entries.isEmpty {
                                Text("Not in any scene yet.").foregroundStyle(.secondary)
                            } else {
                                Text("\(appearances.entries.count) scenes · \(appearances.totalSpeeches) speeches")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(appearances.entries) { entry in
                                HStack {
                                    Text("\(entry.scene.number)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                                    Text(entry.scene.scene.heading).lineLimit(1)
                                    Spacer()
                                    if entry.speeches > 0 { Text("\(entry.speeches)").foregroundStyle(.secondary).help("Speeches in this scene") }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { session.open(scene: entry.scene) }
                            }
                        }
                    }
                    let unresolved = graph.unresolved(in: path)
                    if !unresolved.isEmpty {
                        Section("Unresolved Links") {
                            ForEach(unresolved) { source in
                                HStack {
                                    Text(source.link.target).foregroundStyle(Color(theme.markdown.brokenLink))
                                    Spacer()
                                    Button("Create…") { session.sheet = .newNote(type: nil, name: source.link.target) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView("No Note", systemImage: "link", description: Text("Open a note to see what links to it."))
            }
        }
        .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
    }

    private var currentPath: String? {
        switch session.area {
        case .universe: session.universeSelection
        case .script: session.script.currentFile
        default: session.selectedFile
        }
    }

    private func open(_ source: LinkSource) {
        if source.kind == .scene, let id = source.sceneID {
            session.open(sceneID: id)
            session.script.reveal(file: source.path, location: source.link.range.location)
        } else if source.kind == .dictionary,
                  let entry = session.dictionary.entries.first(where: { $0.lines.contains(source.line) }) {
            session.showInDictionary(entry)
        } else {
            session.open(source.path, location: source.link.range.location)
        }
    }
}

private struct BacklinkRow: View {
    let source: LinkSource
    let graph: LinkGraph

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(source.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch source.kind {
        case .scene: source.sceneHeading ?? (source.path as NSString).lastPathComponent
        case .margin: "Margin · " + (source.path as NSString).lastPathComponent
        case .draft: "Rough Draft"
        case .dictionary: "Dictionary"
        case .canvas: "Canvas · " + ((source.path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .timeline: "Timeline · " + TimelinePane.title(source.path)
        case .map: "Map · " + MapPane.title(source.path)
        case .note: graph.note(at: source.path)?.name ?? source.path
        }
    }

    private var symbol: String {
        switch source.kind {
        case .scene: "film"
        case .margin: "note.text"
        case .draft: "doc.richtext"
        case .dictionary: "character.book.closed"
        case .canvas: "rectangle.3.group"
        case .timeline: "timeline.selection"
        case .map: "map"
        case .note: icon(for: graph.note(at: source.path)?.type)
        }
    }
}

// MARK: - Rename

struct RenameNoteSheet: View {
    let session: ProjectSession
    let path: String
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(session: ProjectSession, path: String, proposed: String?) {
        self.session = session
        self.path = path
        _name = State(initialValue: proposed ?? session.links.graph.note(at: path)?.name ?? "")
    }

    var body: some View {
        let plan = session.renamePlan(for: path, to: name)
        let oldName = session.links.graph.note(at: path)?.name ?? ""
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename “\(oldName)”").font(.headline)
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let plan { apply(plan, updateLinks: true) } }
            if let plan {
                if plan.edits.isEmpty {
                    Text("No links to update.").foregroundStyle(.secondary)
                } else {
                    Text("Update \(plan.edits.count) \(plan.edits.count == 1 ? "link" : "links") in \(plan.fileCount) \(plan.fileCount == 1 ? "file" : "files")?")
                    List(plan.edits) { edit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(edit.path).font(.caption).foregroundStyle(.secondary)
                            Text(edit.context).lineLimit(2)
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    .listStyle(.bordered)
                }
                if let newPath = plan.newPath {
                    Text("The file becomes \((newPath as NSString).lastPathComponent). Its id stays the same, so nothing else breaks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Links written with an alias still work and are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename Only") { if let plan { apply(plan, updateLinks: false) } }
                    .disabled(plan == nil)
                Button("Update Links") { if let plan { apply(plan, updateLinks: true) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func apply(_ plan: RenameRefactor.Plan, updateLinks: Bool) {
        guard plan.newName != plan.oldName || plan.newPath != nil else {
            dismiss()
            return
        }
        session.rename(plan, updateLinks: updateLinks)
        dismiss()
    }
}

// MARK: - New note

struct NewNoteSheet: View {
    let session: ProjectSession
    @State private var type: String
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(session: ProjectSession, type: String?, name: String) {
        self.session = session
        _type = State(initialValue: type ?? (name.isEmpty ? "character" : "note"))
        _name = State(initialValue: name)
    }

    var body: some View {
        let template = session.templates.first { $0.type == type }
        VStack(alignment: .leading, spacing: 14) {
            Text("New Note").font(.headline)
            Form {
                Picker("Template", selection: $type) {
                    ForEach(session.templates) { template in
                        Label(template.label, systemImage: template.icon ?? icon(for: template.type)).tag(template.type)
                    }
                }
                TextField("Name", text: $name)
                    .onSubmit(create)
            }
            if let template {
                Text("Saved as \(template.path(forName: name.isEmpty ? "Untitled \(template.label)" : name, existing: Set(session.allPaths)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Edit Templates…") {
                    let type = type
                    dismiss()
                    DispatchQueue.main.async { session.sheet = .templates(type) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(template == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        guard let template = session.templates.first(where: { $0.type == type }) else { return }
        do {
            try session.createNote(template: template, name: name)
            dismiss()
        } catch {
            SlateAppModel.showError("Couldn't create the note", error)
        }
    }
}

// MARK: - Palettes

/// The shared look of Quick Open and Find in Project: a field on top, a
/// list below, ↑/↓ to choose, Return to open, Esc to close.
struct PaletteSheet<Row: View>: View {
    let prompt: String
    @Binding var query: String
    let count: Int
    let emptyText: String
    let row: (Int, Bool) -> Row
    let choose: (Int) -> Void

    init(prompt: String, query: Binding<String>, count: Int, emptyText: String,
         @ViewBuilder row: @escaping (Int, Bool) -> Row, choose: @escaping (Int) -> Void) {
        self.prompt = prompt
        _query = query
        self.count = count
        self.emptyText = emptyText
        self.row = row
        self.choose = choose
    }

    @State private var selection = 0
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { pick(selection) }
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0)
                    return .handled
                }
                .onChange(of: query) { selection = 0 }
            Divider()
            ScrollViewReader { proxy in
                List(0..<count, id: \.self) { index in
                    row(index, index == selection)
                        .listRowBackground(index == selection ? Color.accentColor.opacity(0.25) : Color.clear)
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture { pick(index) }
                }
                .onChange(of: selection) { _, index in proxy.scrollTo(index) }
            }
            .overlay {
                if count == 0 { Text(emptyText).foregroundStyle(.secondary) }
            }
        }
        .frame(width: 560, height: 400)
        .onAppear { fieldFocused = true }
        .background {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    private func pick(_ index: Int) {
        guard index >= 0, index < count else { return }
        choose(index)
        dismiss()
    }
}

/// ⌘P: notes, scenes and files by fuzzy name.
struct QuickOpenSheet: View {
    let session: ProjectSession
    @State private var query = ""

    var body: some View {
        let items = QuickOpen.rank(session.quickOpenItems, query: query)
        PaletteSheet(prompt: "Open note, scene or file", query: $query, count: items.count, emptyText: "No matches") { index, _ in
            let item = items[index]
            HStack(spacing: 8) {
                Image(systemName: symbol(item)).foregroundStyle(.secondary).frame(width: 18)
                Text(item.title).lineLimit(1)
                Spacer()
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } choose: { index in
            session.open(items[index])
        }
    }

    private func symbol(_ item: QuickOpen.Item) -> String {
        switch item.kind {
        case .note: icon(for: session.links.graph.note(at: item.path)?.type)
        case .scene: "film"
        case .file: "doc"
        }
    }
}

/// ⇧⌘F: every text file in the project, open edits included.
struct ProjectSearchSheet: View {
    @Bindable var session: ProjectSession
    @State private var results: [ProjectSearch.FileResult] = []
    @State private var searching = false

    var body: some View {
        let matches = results.flatMap(\.matches)
        PaletteSheet(prompt: "Find in project (use \"quotes\" for an exact phrase)", query: $session.searchQuery, count: matches.count,
                     emptyText: session.searchQuery.isEmpty ? "Type to search notes, script and margin" : searching ? "Searching…" : "No matches") { index, _ in
            let match = matches[index]
            VStack(alignment: .leading, spacing: 2) {
                if index == 0 || matches[index - 1].path != match.path {
                    Text(match.path).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(highlighted(match)).lineLimit(2)
            }
        } choose: { index in
            session.open(matches[index].path, location: matches[index].range.location)
        }
        .task(id: session.searchQuery) {
            let query = session.searchQuery
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                results = []
                return
            }
            searching = true
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let root = session.store.rootURL
            let paths = session.allPaths
            let overrides = Dictionary(uniqueKeysWithValues: session.store.documents.values.filter(\.isDirty).map { ($0.relativePath, $0.text) })
            let found = await Task.detached(priority: .userInitiated) {
                ProjectSearch.search(query, root: root, paths: paths, overrides: overrides)
            }.value
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }

    private func highlighted(_ match: ProjectSearch.Match) -> AttributedString {
        var text = AttributedString(match.snippet)
        let ns = match.snippet as NSString
        guard NSMaxRange(match.snippetRange) <= ns.length,
              let range = Range(match.snippetRange, in: match.snippet),
              let lower = AttributedString.Index(range.lowerBound, within: text),
              let upper = AttributedString.Index(range.upperBound, within: text) else { return text }
        text[lower..<upper].backgroundColor = .yellow.opacity(0.45)
        text[lower..<upper].font = .body.bold()
        return text
    }
}
