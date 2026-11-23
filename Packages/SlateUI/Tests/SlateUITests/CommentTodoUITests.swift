import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@Suite("TODO comments in the editors")
@MainActor
struct CommentTodoUITests {
    @Test func newTodoInANoteGoesAtTheCaret() {
        let textView = NSTextView()
        textView.string = "Juno keeps the light."
        textView.setSelectedRange(NSRange(location: 21, length: 0))
        CommentTodoEditing.insertNew(in: textView)
        #expect(textView.string == "Juno keeps the light. %% TODO:  %%")
        // The caret waits after "TODO: ".
        #expect(textView.selectedRange().location == ("Juno keeps the light. %% TODO: " as NSString).length)
        textView.insertText("check the bell", replacementRange: textView.selectedRange())
        #expect(CommentTodos.scan(text: textView.string, path: "universe/notes/a.md").first?.text == "check the bell")
    }

    @Test func rightClickTicksTheCommentUnderThePointer() throws {
        let textView = NSTextView()
        textView.string = "Intro\n%% TODO: check dates %%\nMore"
        #expect(CommentTodoEditing.menuItems(at: 2, in: textView, script: false).isEmpty)
        let items = CommentTodoEditing.menuItems(at: 12, in: textView, script: false)
        #expect(items.map(\.title) == ["Mark To-do Done"])
        let todo = try #require(CommentTodoEditing.todo(at: 12, in: textView, script: false))
        CommentTodoEditing.toggle(todo, in: textView)
        #expect(textView.string == "Intro\n%% DONE: check dates %%\nMore")
        // Script editors only read /* */.
        #expect(CommentTodoEditing.todo(at: 12, in: textView, script: true) == nil)
    }

    @Test func theMarginListsScriptCommentsAndTicksThemInTheDocument() throws {
        let h = try SessionHarness()
        let margin = h.session.script.margin
        let path = "script/script.md"
        let document = try h.store.document(at: path)
        document.text = document.text.replacingOccurrences(of: "CUT TO:", with: "/* TODO: sharpen the flicker due:2026-12-24 */\n\nCUT TO:")
        margin.scope = .scene
        let files = h.session.script.scriptFiles.map(\.relativePath)
        let comments = margin.visibleCommentTodos(files: files, currentScene: "s014")
        #expect(comments.map(\.text) == ["sharpen the flicker"])
        #expect(comments.first?.due == "2026-12-24")
        #expect(margin.visibleCommentTodos(files: files, currentScene: "s999").isEmpty)

        margin.toggle(try #require(comments.first))
        #expect(document.text.contains("/* DONE: sharpen the flicker"))
        #expect(!(try h.read(path)).contains("DONE:"))  // through the document, saved by autosave
        #expect(margin.visibleCommentTodos(files: files, currentScene: "s014").isEmpty)
    }

    @Test func openingANoteAtACommentRevealsIt() throws {
        let h = try SessionHarness()
        let note = try #require(h.session.links.graph.notes.first { $0.path.hasPrefix("universe/characters/") })
        h.session.open(note.path, location: 42)
        #expect(h.session.area == .universe)
        #expect(h.session.universeSelection == note.path)
        #expect(h.session.noteReveal?.location == 42)
    }
}
