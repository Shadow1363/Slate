import Foundation
import Observation
import SlateCore

/// The Script area's margin: to-dos and notes for the open project, read
/// from and written to `script/margin/todos.md` and `notes.md` through
/// their open documents, so autosave, outside edits and conflicts work as
/// for any other file.
@MainActor
@Observable
final class MarginModel {
    enum Scope: String, CaseIterable, Identifiable {
        case scene, all
        var id: String { rawValue }
        var title: String { self == .scene ? "This Scene" : "All" }
    }

    enum TodoFilter: String, CaseIterable, Identifiable {
        case open, done, all
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum TodoOrder: String, CaseIterable, Identifiable {
        case scene, due
        var id: String { rawValue }
        var title: String { self == .scene ? "By Scene" : "By Due Date" }
    }

    let store: ProjectStore
    var scope: Scope = .scene
    var filter: TodoFilter = .open
    var order: TodoOrder = .scene
    /// A note shown in the margin instead of the lists (a link was clicked).
    var peek: String?
    private(set) var error: String?

    init(store: ProjectStore) {
        self.store = store
    }

    // MARK: - Files

    private func document(_ path: String) -> TextDocument? {
        if let open = store.documents[path] { return open }
        if !store.files.values.contains(where: { $0.contains { $0.relativePath == path } }) {
            do {
                return try store.createTextFile(at: path)
            } catch {
                self.error = error.localizedDescription
                return nil
            }
        }
        do {
            return try store.document(at: path)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    var todosText: String { (try? store.readText(at: MarginTodos.path)) ?? "" }
    var notesText: String { (try? store.readText(at: MarginNotes.path)) ?? "" }

    var todos: [MarginTodo] { MarginTodos.parse(todosText) }
    var notes: [MarginNote] { MarginNotes.parse(notesText) }

    /// Applies an edit to a margin file; nil from `change` means the item
    /// moved since it was shown (the file was edited elsewhere).
    private func edit(_ path: String, _ change: (String) -> String?) {
        guard let document = document(path) else { return }
        guard let updated = change(document.text) else {
            error = "That item changed in the file since it was shown. The list has been refreshed."
            return
        }
        error = nil
        if updated != document.text { document.text = updated }
    }

    // MARK: - To-dos

    func add(_ todo: MarginTodo) {
        edit(MarginTodos.path) { MarginTodos.adding(todo, to: $0) }
    }

    func toggle(_ todo: MarginTodo) {
        edit(MarginTodos.path) { MarginTodos.toggling(todo, in: $0) }
    }

    func update(_ todo: MarginTodo, to updated: MarginTodo) {
        edit(MarginTodos.path) { MarginTodos.replacing(todo, with: updated, in: $0) }
    }

    func delete(_ todo: MarginTodo) {
        edit(MarginTodos.path) { MarginTodos.removing(todo, in: $0) }
    }

    /// To-dos for the list, after scope, filter and order.
    /// `/* TODO: */` comments in these script files (the open film's), per the scope and filter.
    func visibleCommentTodos(files: [String], currentScene: String?) -> [CommentTodo] {
        var list = files.flatMap { path in
            (try? store.readText(at: path)).map { CommentTodos.scan(text: $0, path: path) } ?? []
        }
        if scope == .scene { list = list.filter { $0.sceneID != nil && $0.sceneID == currentScene } }
        switch filter {
        case .open: list = list.filter { !$0.done }
        case .done: list = list.filter(\.done)
        case .all: break
        }
        return list
    }

    /// Ticks a `TODO:` comment through its open document.
    func toggle(_ todo: CommentTodo) {
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

    func visibleTodos(currentScene: String?, sceneOrder: [String]) -> [MarginTodo] {
        var list = todos
        if scope == .scene { list = list.filter { $0.sceneID != nil && $0.sceneID == currentScene } }
        switch filter {
        case .open: list = list.filter { !$0.done }
        case .done: list = list.filter(\.done)
        case .all: break
        }
        switch order {
        case .due:
            return MarginTodos.sorted(list)
        case .scene:
            let rank = Dictionary(sceneOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            return list.sorted { a, b in
                let ra = a.sceneID.flatMap { rank[$0] } ?? Int.max
                let rb = b.sceneID.flatMap { rank[$0] } ?? Int.max
                return ra != rb ? ra < rb : a.line < b.line
            }
        }
    }

    // MARK: - Notes

    func addNote(_ markdown: String, quote: String?, sceneID: String?) {
        edit(MarginNotes.path) { MarginNotes.adding(markdown, quote: quote, sceneID: sceneID, to: $0) }
    }

    func update(_ note: MarginNote, markdown: String) {
        edit(MarginNotes.path) { MarginNotes.replacing(note, with: markdown, quote: note.quote, in: $0) }
    }

    func delete(_ note: MarginNote) {
        edit(MarginNotes.path) { MarginNotes.removing(note, in: $0) }
    }

    func visibleNotes(currentScene: String?, sceneOrder: [String]) -> [MarginNote] {
        let all = notes
        if scope == .scene { return all.filter { $0.sceneID != nil && $0.sceneID == currentScene } }
        let rank = Dictionary(sceneOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return all.sorted { a, b in
            let ra = a.sceneID.flatMap { rank[$0] } ?? -1
            let rb = b.sceneID.flatMap { rank[$0] } ?? -1
            return ra != rb ? ra < rb : a.lines.lowerBound < b.lines.lowerBound
        }
    }

    /// Scene ID → quoted words to highlight in the script.
    var anchors: [(sceneID: String, quote: String)] {
        let fromTodos = todos.filter { !$0.done }.compactMap { todo in todo.sceneID.flatMap { id in todo.quote.map { (id, $0) } } }
        let fromNotes = notes.compactMap { note in note.sceneID.flatMap { id in note.quote.map { (id, $0) } } }
        return (fromTodos + fromNotes).map { (sceneID: $0.0, quote: $0.1) }
    }
}
