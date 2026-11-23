import Foundation
import Testing
@testable import SlateCore

@Suite("TODO comments")
struct CommentTodoTests {
    @Test func notesAcceptBothCommentForms() {
        let text = """
        ---
        type: character
        name: Juno Hale
        ---
        ## Want
        %% TODO: check the 1987 dates due:2026-12-01 %%
        <!-- todo: add her
             mother -->
        <!-- just a comment -->
        TODO: a plain line is not a to-do
        %% DONE: name the boat %%
        """
        let todos = CommentTodos.scan(text: text, path: "universe/characters/juno-hale.md")
        #expect(todos.map(\.text) == ["check the 1987 dates", "add her mother", "name the boat"])
        #expect(todos.map(\.done) == [false, false, true])
        #expect(todos[0].due == "2026-12-01")
        #expect(todos[0].line == 5)
        #expect(todos.allSatisfy { $0.place == "Juno Hale" })
        #expect(todos[0].sceneID == nil)
    }

    @Test func scriptOnlyReadsBoneyardAndKnowsTheScene() {
        let text = """
        INT. KITCHEN - NIGHT {#s014}

        /* TODO: tighten this exchange */

        %% TODO: not a comment in a script %%

        EXT. ROOF - DAWN {#s015}

        /*
        TODO: a longer note
        over two lines due:2026-12-24
        */
        """
        let todos = CommentTodos.scan(text: text, path: "script/script.md")
        #expect(todos.map(\.text) == ["tighten this exchange", "a longer note over two lines"])
        #expect(todos.map(\.sceneID) == ["s014", "s015"])
        #expect(todos.map(\.place) == ["INT. KITCHEN - NIGHT", "EXT. ROOF - DAWN"])
        #expect(todos[1].due == "2026-12-24")
    }

    @Test func togglingSwapsTheWordAndChecksPosition() throws {
        let text = "Intro\n%% TODO: check dates %%\n"
        let todo = try #require(CommentTodos.scan(text: text, path: "universe/notes/a.md").first)
        let done = try #require(CommentTodos.toggling(todo, in: text))
        #expect(done == "Intro\n%% DONE: check dates %%\n")
        let back = try #require(CommentTodos.scan(text: done, path: "universe/notes/a.md").first)
        #expect(CommentTodos.toggling(back, in: done) == text)
        // Something moved: refused.
        #expect(CommentTodos.toggling(todo, in: "More intro\n" + text) == nil)
    }

    @Test func revisionsAndTheMarginAreNotScanned() {
        #expect(CommentTodos.isScanned("script/script.md"))
        #expect(CommentTodos.isScanned("script/01 Tidewater/01-act-one.md"))
        #expect(!CommentTodos.isScanned("script/01 Tidewater/revisions/01 blue/01-act-one.md"))
        #expect(!CommentTodos.isScanned("script/margin/todos.md"))
        #expect(!CommentTodos.isScanned("script/title-page.md"))
        #expect(CommentTodos.isScanned("universe/draft.md"))
        #expect(!CommentTodos.isScanned("storyboard/notes.md"))
    }

    @Test func pendingMergesCommentsWithTheMarginAndCountsThem() throws {
        let folder = try TempFolder()
        let sample = try Fixtures.copySampleProject(into: folder)
        try folder.write("- [x] all done\n", to: "Other/script/margin/todos.md")
        let draft = try String(contentsOf: sample.appending(path: "universe/draft.md"), encoding: .utf8)
        try (draft + "\n%% TODO: a draft thought due:2026-11-01 %%\n").write(to: sample.appending(path: "universe/draft.md"), atomically: true, encoding: .utf8)
        let pending = Reminders.pending(in: sample, today: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(pending.count == 4)
        // Its due date is the earliest, so it comes first.
        let first = try #require(pending.first)
        #expect(first.isComment)
        #expect(first.todo.text == "a draft thought")
        #expect(ProjectSummary.load(at: sample)?.openTodos == 4)

        let plan = Reminders.plan(projectName: "S", projectRoot: sample, pending: pending, now: Date(timeIntervalSince1970: 1_761_000_000))
        let reminder = try #require(plan.first { $0.path == "universe/draft.md" })
        #expect(reminder.location != nil)
    }
}
