import AppKit
import SlateCore
import SwiftUI

/// The collapsible column beside the script: To-dos and Notes, or a peek
/// at a linked note.
struct MarginView: View {
    let session: ProjectSession
    @Bindable var margin: MarginModel

    var body: some View {
        VStack(spacing: 0) {
            if let path = margin.peek {
                NotePeek(session: session, path: path) { margin.peek = nil }
            } else {
                Picker("Margin", selection: $margin.tab) {
                    ForEach(MarginModel.Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                HStack {
                    Picker("Scope", selection: $margin.scope) {
                        ForEach(MarginModel.Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if margin.tab == .todos {
                        Menu {
                            Picker("Show", selection: $margin.filter) {
                                ForEach(MarginModel.TodoFilter.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("Order", selection: $margin.order) {
                                ForEach(MarginModel.TodoOrder.allCases) { Text($0.title).tag($0) }
                            }
                        } label: {
                            Label(margin.filter.title, systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Filter and order to-dos")
                    }
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                if let error = margin.error {
                    Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10)
                }
                Divider()
                switch margin.tab {
                case .todos: TodoList(session: session, margin: margin)
                case .notes: NoteList(session: session, margin: margin)
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
        .background(.background)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == LinkURL.scheme, let target = LinkURL.target(from: url) else { return .systemAction }
            session.peekLink(target)
            return .handled
        })
    }
}

/// `slate-link:` URLs carry `[[link]]` targets through SwiftUI `Text`.
enum LinkURL {
    static let scheme = "slate-link"

    static func url(for target: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.path = target
        return components.url
    }

    static func target(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
    }

    /// Markdown with `[[links]]` turned into clickable `slate-link:` links.
    static func attributed(_ markdown: String) -> AttributedString {
        var text = ""
        var last = markdown.startIndex
        for link in WikiLink.find(in: markdown) {
            guard let range = Range(link.range, in: markdown), let url = url(for: link.target) else { continue }
            text += markdown[last..<range.lowerBound]
            let shown = link.displayText.replacingOccurrences(of: "]", with: "\\]")
            text += "[\(shown)](\(url.absoluteString))"
            last = range.upperBound
        }
        text += markdown[last...]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(markdown)
    }
}

// MARK: - To-dos

private struct TodoList: View {
    let session: ProjectSession
    let margin: MarginModel
    @State private var draft = ""

    var body: some View {
        let script = session.script
        let todos = margin.visibleTodos(currentScene: script.currentSceneID, sceneOrder: script.sceneOrder)
        VStack(spacing: 0) {
            List {
                ForEach(todos) { todo in
                    TodoRow(session: session, todo: todo)
                }
            }
            .listStyle(.plain)
            .overlay {
                if todos.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "checklist", description: Text("Add one below, or press ⇧⌘T in the script."))
                }
            }
            Divider()
            HStack {
                TextField(script.currentSceneID == nil ? "New to-do" : "New to-do for this scene", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    private var emptyTitle: String {
        margin.scope == .scene ? (session.script.currentSceneID == nil ? "No Scene" : "Nothing for This Scene") : "No To-dos"
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        margin.add(MarginTodo(text: text, sceneID: margin.scope == .scene ? session.script.currentSceneID : nil))
        draft = ""
    }
}

private struct TodoRow: View {
    let session: ProjectSession
    let todo: MarginTodo
    @Environment(\.slateTheme) private var theme

    var body: some View {
        let margin = session.script.margin
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                margin.toggle(todo)
            } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.done ? Color(theme.margin.done) : Color(theme.margin.todo))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.done ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 3) {
                if let quote = todo.quote {
                    Text("“\(quote)”").italic().foregroundStyle(.secondary).lineLimit(2)
                }
                Text(LinkURL.attributed(todo.text))
                    .strikethrough(todo.done)
                    .foregroundStyle(todo.done ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let id = todo.sceneID {
                        SceneChip(session: session, sceneID: id, quote: todo.quote)
                    }
                    if let due = todo.due {
                        Label(DueText.format(due), systemImage: "calendar")
                            .foregroundStyle(todo.isOverdue() ? Color(theme.margin.overdue) : .secondary)
                            .help(todo.isOverdue() ? "Overdue" : "Due \(due)")
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit…") { session.sheet = .editTodo(todo) }
            if let id = todo.sceneID {
                Button("Go to Scene") { session.script.reveal(sceneID: id, quote: todo.quote) }
            }
            Divider()
            Button("Delete", role: .destructive) { margin.delete(todo) }
        }
    }
}

/// "Scene 14" (or "Scene removed"), click to go there.
struct SceneChip: View {
    let session: ProjectSession
    let sceneID: String
    let quote: String?

    var body: some View {
        let scene = session.script.scene(withID: sceneID)
        Button {
            session.area = .script
            session.script.reveal(sceneID: sceneID, quote: quote)
        } label: {
            Text(scene.map { "Scene \($0.number)" } ?? "Scene removed")
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(scene == nil)
        .help(scene.map { $0.scene.heading } ?? "No scene has the ID \(sceneID) any more.")
    }
}

enum DueText {
    static func format(_ due: String) -> String {
        guard let date = MarginTodo(text: "", due: due).dueDate() else { return due }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Notes

private struct NoteList: View {
    let session: ProjectSession
    let margin: MarginModel
    @State private var draft = ""

    var body: some View {
        let script = session.script
        let notes = margin.visibleNotes(currentScene: script.currentSceneID, sceneOrder: script.sceneOrder)
        VStack(spacing: 0) {
            List {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        if margin.scope == .all {
                            if let id = note.sceneID {
                                SceneChip(session: session, sceneID: id, quote: note.quote).font(.caption)
                            } else {
                                Text("General").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let quote = note.quote {
                            Button {
                                if let id = note.sceneID { script.reveal(sceneID: id, quote: quote) }
                            } label: {
                                Text("“\(quote)”").italic().foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                            .help("Show these words in the script")
                        }
                        Text(LinkURL.attributed(note.text))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        Button("Edit…") { session.sheet = .editNote(note) }
                        Divider()
                        Button("Delete", role: .destructive) { margin.delete(note) }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if notes.isEmpty {
                    ContentUnavailableView(margin.scope == .scene ? "No Notes for This Scene" : "No Notes", systemImage: "note.text",
                                           description: Text("Add one below, or press ⌥⌘T in the script. Select words first to anchor it to them."))
                }
            }
            Divider()
            HStack {
                TextField("New note (use [[links]])", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        margin.addNote(text, quote: nil, sceneID: margin.scope == .scene ? session.script.currentSceneID : nil)
        draft = ""
    }
}

// MARK: - Note previews

/// A linked note inside the margin, without leaving the script.
private struct NotePeek: View {
    let session: ProjectSession
    let path: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Open in Universe") { session.open(path) }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            Divider()
            ScrollView {
                NotePreviewCard(session: session, path: path, bodyLimit: nil)
                    .padding(14)
            }
        }
    }
}

/// Name, type, filled-in fields and the body (or its start) of a note.
struct NotePreviewCard: View {
    let session: ProjectSession
    let path: String
    /// Characters of body to show; nil for all.
    let bodyLimit: Int?

    var body: some View {
        let graph = session.links.graph
        if let note = graph.note(at: path) {
            let text = (try? session.store.readText(at: path)) ?? ""
            let body = Frontmatter.split(text).body.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: session.template(for: note.type)?.icon ?? icon(for: note.type)).foregroundStyle(.secondary)
                    Text(note.name).font(.headline)
                    Spacer()
                    Text(session.template(for: note.type)?.label ?? "Note")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // The infobox, without its own title (the header above has it).
                let content = InfoboxContent.make(note: note, template: session.template(for: note.type), store: session.store)
                    .limited(to: bodyLimit == nil ? nil : 6)
                if let subtitle = content.subtitle {
                    SpoilerText(text: subtitle).font(.caption.italic()).foregroundStyle(.secondary)
                }
                InfoboxRows(content: content)
                if !body.isEmpty {
                    Divider()
                    let shown = bodyLimit.map { body.count > $0 ? String(body.prefix($0)) + "…" : body } ?? body
                    Text(LinkURL.attributed(shown))
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "questionmark.folder")
        }
    }
}

// MARK: - Sheets

/// ⇧⌘T, and Edit… on a to-do.
struct TodoSheet: View {
    let session: ProjectSession
    let original: MarginTodo?
    @State private var todo: MarginTodo
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @Environment(\.dismiss) private var dismiss

    init(session: ProjectSession, editing original: MarginTodo?, sceneID: String?, quote: String?) {
        self.session = session
        self.original = original
        let start = original ?? MarginTodo(text: "", sceneID: sceneID, quote: quote)
        _todo = State(initialValue: start)
        let date = start.dueDate()
        _hasDue = State(initialValue: date != nil)
        _dueDate = State(initialValue: date ?? Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "New To-do" : "Edit To-do").font(.headline)
            Form {
                TextField("To-do", text: $todo.text)
                if let quote = todo.quote {
                    LabeledContent("Words") {
                        HStack {
                            Text("“\(quote)”").italic().lineLimit(2)
                            Button("Remove") { todo.quote = nil }.buttonStyle(.borderless)
                        }
                    }
                }
                LabeledContent("Scene") {
                    if let id = todo.sceneID {
                        HStack {
                            Text(session.script.scene(withID: id).map { "\($0.number). \($0.scene.heading)" } ?? id).lineLimit(1)
                            Button("Remove") { todo.sceneID = nil }.buttonStyle(.borderless)
                        }
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                Toggle("Due date", isOn: $hasDue)
                if hasDue {
                    DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(todo.text.trimmingCharacters(in: .whitespaces).isEmpty && todo.quote == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        var result = todo
        result.text = result.text.trimmingCharacters(in: .whitespaces)
        result.due = hasDue ? dueDate.formatted(.iso8601.year().month().day()) : nil
        let margin = session.script.margin
        if let original { margin.update(original, to: result) } else { margin.add(result) }
        session.script.showingMargin = true
        margin.tab = .todos
        dismiss()
    }
}

/// ⌥⌘T, and Edit… on a note.
struct MarginNoteSheet: View {
    let session: ProjectSession
    let original: MarginNote?
    let sceneID: String?
    let quote: String?
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(session: ProjectSession, editing original: MarginNote?, sceneID: String?, quote: String?) {
        self.session = session
        self.original = original
        self.sceneID = original?.sceneID ?? sceneID
        self.quote = original?.quote ?? quote
        _text = State(initialValue: original?.text ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "New Margin Note" : "Edit Margin Note").font(.headline)
            if let quote { Text("On “\(quote)”").italic().foregroundStyle(.secondary).lineLimit(2) }
            if let sceneID {
                Text(session.script.scene(withID: sceneID).map { "Scene \($0.number): \($0.scene.heading)" } ?? sceneID)
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            Text("Use [[Name]] to link a note.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        let margin = session.script.margin
        if let original {
            margin.update(original, markdown: text)
        } else {
            margin.addNote(text, quote: quote, sceneID: sceneID)
        }
        session.script.showingMargin = true
        margin.tab = .notes
        dismiss()
    }
}
