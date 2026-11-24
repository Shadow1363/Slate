import AppKit
import Observation
import SlateCore
import SwiftUI

/// The Universe area's margin: the TODO comments in notes (`%% TODO: … %%`,
/// `<!-- TODO: … -->`), in the sidebar's To-dos tab like the script's.
@MainActor
@Observable
final class NoteMarginModel {
    enum Scope: String, CaseIterable, Identifiable {
        case note, all
        var id: String { rawValue }
        var title: String { self == .note ? "This Note" : "All Notes" }
    }

    let store: ProjectStore
    var scope: Scope = .note
    var filter: MarginModel.TodoFilter = .open
    private(set) var error: String?

    init(store: ProjectStore) {
        self.store = store
    }

    /// Markdown files in Universe (notes and the draft).
    private var notePaths: [String] {
        (store.files[.universe] ?? []).map(\.relativePath).filter { $0.hasSuffix(".md") }.sorted()
    }

    /// TODO comments for the open note (or every note), per the filter, from the live text.
    func todos(selected: String?) -> [CommentTodo] {
        let paths: [String]
        switch scope {
        case .note: paths = selected.map { $0.hasSuffix(".md") ? [$0] : [] } ?? []
        case .all: paths = notePaths
        }
        var list = paths.flatMap { path in
            (try? store.readText(at: path)).map { CommentTodos.scan(text: $0, path: path) } ?? []
        }
        switch filter {
        case .open: list = list.filter { !$0.done }
        case .done: list = list.filter(\.done)
        case .all: break
        }
        return list
    }

    /// TODO → DONE (or back) through the note's open document.
    func toggle(_ todo: CommentTodo) {
        error = nil
        do {
            let document = try store.document(at: todo.path)
            guard let updated = CommentTodos.toggling(todo, in: document.text) else {
                error = "That comment changed since it was shown. The list has been refreshed."
                return
            }
            document.text = updated
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Adds `%% TODO: words %%` at the end of a note. Returns where the comment starts.
    @discardableResult
    func add(_ words: String, to path: String) -> Int? {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, path.hasSuffix(".md") else { return nil }
        error = nil
        do {
            let document = try store.document(at: path)
            var text = document.text
            while text.hasSuffix("\n\n") { text.removeLast() }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            let location = (text as NSString).length + (text.isEmpty ? 0 : 1)
            text += (text.isEmpty ? "" : "\n") + "%% TODO: \(words) %%\n"
            document.text = text
            return location
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

struct NoteMarginView: View {
    let session: ProjectSession
    @Bindable var margin: NoteMarginModel
    @State private var draft = ""

    var body: some View {
        let selected = session.universeSelection
        let canAdd = selected?.hasSuffix(".md") ?? false
        let todos = margin.todos(selected: selected)
        VStack(spacing: 0) {
            PanelFilterBar {
                PanelMenu(title: margin.scope.title, help: "This note's to-dos, or every note's") {
                    Picker("Show", selection: $margin.scope) {
                        ForEach(NoteMarginModel.Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            } trailing: {
                PanelMenu(title: margin.filter.title, systemImage: "line.3.horizontal.decrease", help: "Show open, done or all to-dos") {
                    Picker("Show", selection: $margin.filter) {
                        ForEach(MarginModel.TodoFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            if let error = margin.error {
                Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10)
            }
            Divider()
            List {
                ForEach(todos) { todo in
                    CommentTodoRow(session: session, todo: todo, showsPlace: margin.scope == .all) { margin.toggle(todo) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if todos.isEmpty {
                    ContentUnavailableView(emptyTitle(selected), systemImage: "checklist",
                                           description: Text("Add one below, press ⇧⌘T in the note, or write %% TODO: … %%."))
                }
            }
            Divider()
            HStack {
                TextField(canAdd ? "New to-do for this note" : "Open a note to add a to-do", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .disabled(!canAdd)
                Button("Add", action: add)
                    .disabled(!canAdd || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .background(.background)
    }

    private func emptyTitle(_ selected: String?) -> String {
        if margin.scope == .all { return "No To-dos" }
        return selected?.hasSuffix(".md") == true ? "Nothing for This Note" : "No Note Open"
    }

    private func add() {
        guard let path = session.universeSelection else { return }
        if margin.add(draft, to: path) != nil { draft = "" }
    }
}

/// A `TODO:` comment in a list (the script's margin or a note's): tick it
/// (TODO → DONE), or click to go to it.
struct CommentTodoRow: View {
    let session: ProjectSession
    let todo: CommentTodo
    var showsPlace = false
    let toggle: () -> Void
    @Environment(\.slateTheme) private var theme

    var body: some View {
        let item = todo.asMarginTodo
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: toggle) {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color(todo.done ? theme.margin.done : theme.margin.todo))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.done ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.text.isEmpty ? "To-do" : todo.text)
                    .strikethrough(todo.done)
                    .foregroundStyle(Color(todo.done ? theme.margin.done : theme.margin.todo))
                HStack(spacing: 6) {
                    Label("Comment", systemImage: "text.bubble").labelStyle(.iconOnly)
                    if showsPlace { Text(todo.place).lineLimit(1) }
                    if let due = todo.due {
                        Text(item.isOverdue() ? "Overdue · \(DueText.format(due))" : "Due \(DueText.format(due))")
                            .foregroundStyle(item.isOverdue() ? Color(theme.margin.overdue) : .secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture { session.reveal(todo) }
        .help("Click to show the comment")
    }
}

extension ProjectSession {
    /// Opens the file of a `TODO:` comment with the comment selected.
    func reveal(_ todo: CommentTodo) {
        open(todo.path, range: todo.range)
    }
}
