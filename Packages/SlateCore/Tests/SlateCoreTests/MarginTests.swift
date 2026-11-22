import Foundation
import Testing
@testable import SlateCore

@Suite("Margin to-dos")
struct MarginTodoTests {
    let file = """
    # To-dos

    - [ ] Fix Mara's motivation before the reveal @s014 due:2026-12-01
    - [ ] "I haven't opened it yet" — make the lie land harder @s014
    - [x] Rename the courier @s021
    Some prose that isn't a to-do.
    """

    @Test func parsesTokensAndQuotes() {
        let todos = MarginTodos.parse(file)
        #expect(todos.count == 3)
        #expect(todos[0].text == "Fix Mara's motivation before the reveal")
        #expect(todos[0].sceneID == "s014")
        #expect(todos[0].due == "2026-12-01")
        #expect(todos[1].quote == "I haven't opened it yet")
        #expect(todos[1].text == "make the lie land harder")
        #expect(todos[2].done)
        #expect(todos[2].line == 4)
    }

    @Test func togglingChangesOnlyTheBox() throws {
        let todos = MarginTodos.parse(file)
        let toggled = try #require(MarginTodos.toggling(todos[0], in: file))
        #expect(toggled == file.replacingOccurrences(of: "- [ ] Fix Mara", with: "- [x] Fix Mara"))
        // A stale to-do (the line changed) is refused.
        #expect(MarginTodos.toggling(todos[0], in: toggled) == nil)
    }

    @Test func editingRewritesTheLineInSlateStyle() throws {
        var todo = MarginTodos.parse(file)[2]
        let original = todo
        todo.text = "Rename the courier properly"
        todo.due = "2027-01-05"
        let edited = try #require(MarginTodos.replacing(original, with: todo, in: file))
        #expect(edited.contains("\n- [x] Rename the courier properly @s021 due:2027-01-05\n"))
        #expect(MarginTodos.parse(edited)[2] .text == "Rename the courier properly")
    }

    @Test func addingAndRemoving() throws {
        let added = MarginTodos.adding(MarginTodo(text: "Check the rain", sceneID: "s003", quote: "Rain hammers"), to: file)
        #expect(added.hasSuffix("Some prose that isn't a to-do.\n- [ ] \"Rain hammers\" — Check the rain @s003\n"))
        let new = try #require(MarginTodos.parse(added).last)
        #expect(new.quote == "Rain hammers")
        #expect(new.sceneID == "s003")
        #expect(MarginTodos.removing(new, in: added) == file + "\n")
    }

    @Test func overdueAndSorting() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2026, month: 12, day: 3))!
        let todos = MarginTodos.parse("""
        - [ ] later due:2026-12-20
        - [ ] undated
        - [x] done due:2026-11-01
        - [ ] late due:2026-12-01
        """)
        #expect(todos[3].isOverdue(today: today, calendar: calendar))
        #expect(!todos[2].isOverdue(today: today, calendar: calendar))
        #expect(MarginTodos.sorted(todos, today: today).map(\.text) == ["late", "later", "undated", "done"])
    }
}

@Suite("Margin notes")
struct MarginNoteTests {
    let file = """
    General thought about the ending.

    ## @s014

    - "I haven't opened it yet" — she has, in the 1998 loop. See [[The Brass Key]].
    - Second note
      that runs on.

    ## @s020 The roof

    - Roof note.
    """

    @Test func parsesScenesQuotesAndContinuations() {
        let notes = MarginNotes.parse(file)
        #expect(notes.map(\.sceneID) == ["s014", "s014", "s020"])
        #expect(notes[0].quote == "I haven't opened it yet")
        #expect(notes[0].text == "she has, in the 1998 loop. See [[The Brass Key]].")
        #expect(notes[0].links.map(\.target) == ["The Brass Key"])
        #expect(notes[1].markdown == "Second note\nthat runs on.")
        #expect(notes[1].lines == 5..<7)
    }

    @Test func addsToTheRightSection() {
        let added = MarginNotes.adding("New one", sceneID: "s014", to: file)
        #expect(added.contains("  that runs on.\n- New one\n\n## @s020"))
        let fresh = MarginNotes.adding("Kitchen", quote: "Rain", sceneID: "s030", to: file)
        #expect(fresh.hasSuffix("- Roof note.\n\n## @s030\n\n- \"Rain\" — Kitchen\n"))
        let general = MarginNotes.adding("Loose", sceneID: nil, to: file)
        #expect(general.hasPrefix("General thought about the ending.\n\n- Loose\n\n## @s014"))
        #expect(MarginNotes.parse(general).first { $0.sceneID == nil }?.markdown == "Loose")
        #expect(MarginNotes.adding("First", sceneID: nil, to: "") == "- First\n")
    }

    @Test func editsAndRemovesOnlyThatItem() throws {
        let notes = MarginNotes.parse(file)
        let edited = try #require(MarginNotes.replacing(notes[1], with: "Shorter", quote: nil, in: file))
        #expect(edited.contains("- Shorter\n\n## @s020"))
        let removed = try #require(MarginNotes.removing(notes[2], in: file))
        #expect(!removed.contains("Roof note"))
        #expect(MarginNotes.removing(notes[2], in: edited) == nil) // lines moved
    }

    @Test func sampleProjectNotes() throws {
        let text = try String(contentsOf: Fixtures.sampleProject.appending(path: MarginNotes.path), encoding: .utf8)
        let notes = MarginNotes.parse(text)
        #expect(notes.count == 1)
        #expect(notes[0].sceneID == "s014")
    }
}

@Suite("Reminders")
struct ReminderTests {
    let calendar = Calendar(identifier: .gregorian)

    @Test func plansNotificationsForUpcomingDueDates() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 8))!
        let todos = MarginTodos.parse("""
        - [ ] today @s014 due:2026-12-01
        - [ ] future due:2026-12-24
        - [ ] past due:2026-11-20
        - [x] done due:2026-12-24
        - [ ] undated
        """)
        let plan = Reminders.plan(projectName: "Film", projectRoot: URL(filePath: "/p"), todos: todos, now: now, calendar: calendar)
        #expect(plan.map(\.body) == ["today", "future"])
        #expect(plan[0].fireDate.day == 1 && plan[0].fireDate.hour == 9)
        #expect(plan[0].sceneID == "s014")
        #expect(Set(plan.map(\.id)).count == 2)
        // After 9:00 on the due date, it fires in a minute.
        let late = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 15))!
        let again = Reminders.plan(projectName: "Film", projectRoot: URL(filePath: "/p"), todos: todos, now: late, calendar: calendar)
        #expect(again[0].fireDate.hour == 15 && again[0].fireDate.minute == 1)
    }

    @Test func launchListSkipsProjectsWithNothingOpen() throws {
        let folder = try TempFolder()
        let sample = try Fixtures.copySampleProject(into: folder)
        try folder.write("- [x] all done\n", to: "Other/script/margin/todos.md")
        let list = Reminders.launchList(projects: [("Sample", sample), ("Other", folder.file("Other"))])
        #expect(list.map(\.name) == ["Sample"])
        #expect(list[0].todos.count == 3)
        #expect(list[0].todos.first?.due == "2026-12-01")
    }
}
