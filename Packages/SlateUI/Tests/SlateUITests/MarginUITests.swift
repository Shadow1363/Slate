import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@Suite("Margin")
@MainActor
struct MarginUITests {
    @Test func todosGoThroughTheOpenDocument() throws {
        let h = try SessionHarness()
        let margin = h.session.script.margin
        #expect(margin.todos.count == 4)
        let open = try #require(margin.todos.first)
        margin.toggle(open)
        let document = try #require(h.store.documents[MarginTodos.path])
        #expect(document.isDirty)
        #expect(document.text.contains("- [x] Fix Mara's motivation"))
        h.store.save(document)
        #expect(try h.read(MarginTodos.path).contains("- [x] Fix Mara's motivation"))

        margin.add(MarginTodo(text: "Check the rain", sceneID: "s014", due: "2027-01-02"))
        #expect(document.text.hasSuffix("- [ ] Check the rain @s014 due:2027-01-02\n"))
    }

    @Test func filtersAndScope() throws {
        let h = try SessionHarness()
        let margin = h.session.script.margin
        margin.scope = .all
        margin.filter = .open
        #expect(margin.visibleTodos(currentScene: nil, sceneOrder: ["s014"]).count == 3)
        margin.filter = .done
        #expect(margin.visibleTodos(currentScene: nil, sceneOrder: ["s014"]).map(\.text) == ["Rename the courier"])
        margin.scope = .scene
        margin.filter = .all
        #expect(margin.visibleTodos(currentScene: "s014", sceneOrder: ["s014"]).count == 3)
        #expect(margin.visibleTodos(currentScene: nil, sceneOrder: ["s014"]).isEmpty)
        margin.order = .due
        margin.scope = .all
        #expect(margin.visibleTodos(currentScene: nil, sceneOrder: []).first?.due == "2026-12-01")
    }

    @Test func notesAndAnchors() throws {
        let h = try SessionHarness()
        let margin = h.session.script.margin
        #expect(margin.notes.count == 1)
        margin.addNote("Is the key [[The Brass Key]] visible?", quote: "brass key", sceneID: "s014")
        let notes = margin.notes
        #expect(notes.count == 2)
        #expect(notes[1].quote == "brass key")
        let anchors = margin.anchors.map(\.quote)
        #expect(anchors.contains("I haven't opened it yet"))
        #expect(anchors.contains("brass key"))
        margin.delete(notes[1])
        #expect(margin.notes.count == 1)
    }

    @Test func revealSelectsTheQuotedWords() throws {
        let h = try SessionHarness()
        let script = h.session.script
        script.reveal(sceneID: "s014", quote: "i haven't opened it yet")
        let reveal = try #require(script.reveal)
        let text = try #require(h.store.documents["script/script.md"]).text as NSString
        #expect(text.substring(with: NSRange(location: reveal.location, length: reveal.length)) == "I haven't opened it yet")
        #expect(script.selectedRow == "scene:s014")
    }

    @Test func addingAtTheCaretUsesSceneAndSelection() throws {
        let h = try SessionHarness()
        let session = h.session
        session.script.caret = ScriptCaret(file: "script/script.md", location: 40, kind: .action, sceneIndex: 0, selection: "brass key")
        session.addTodoAtCaret()
        guard case .addTodo(let scene, let quote) = session.sheet else {
            Issue.record("Expected the add to-do sheet")
            return
        }
        #expect(scene == "s014")
        #expect(quote == "brass key")
    }

    @Test func scriptLinksPeekInTheMargin() throws {
        let h = try SessionHarness()
        let session = h.session
        session.script.showingMargin = false
        #expect(session.script.followLink("the key"))
        #expect(session.script.showingMargin)
        #expect(session.script.margin.peek == "universe/items/the-brass-key.md")
        #expect(session.area == .script)
        #expect(session.linkPreview("The Station") != nil)
        #expect(session.linkPreview("Nobody") == nil)
        _ = session.script.followLink("Nobody")
        guard case .newNote(_, let name) = session.sheet else {
            Issue.record("Expected the new note sheet")
            return
        }
        #expect(name == "Nobody")
    }

    @Test func linksBecomeClickableInMarginText() throws {
        let text = LinkURL.attributed("See [[The Brass Key|the key]] and **this**.")
        #expect(String(text.characters) == "See the key and this.")
        let link = text.runs.compactMap(\.link).first
        #expect(link.flatMap(LinkURL.target(from:)) == "The Brass Key")
    }
}
