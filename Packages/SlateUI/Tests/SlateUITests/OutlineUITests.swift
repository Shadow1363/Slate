import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Universe heading index")
struct OutlineUITests {
    static let tree = HeadingTree.build(MarkdownOutline(parsing: "## A\n\n### A1\n\n#### A1a\n\n## B\n").headings)

    @Test func openStateTogglesAndIsRemembered() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlateOutline-\(UUID().uuidString)")
        let state = OutlineState(projectRoot: root)
        defer { UserDefaults.standard.removeObject(forKey: state.defaultsKey) }
        let note = "universe/characters/juno.md"
        // Notes start closed, the draft open.
        #expect(!state.isOpen(note))
        #expect(state.isOpen(ProjectLayout.draft))
        state.toggle(note, tree: Self.tree, branch: false)
        #expect(state.isOpen(note))
        #expect(!state.isOpen(note, heading: "A"))
        // ⌥-click opens the whole branch.
        state.toggle(note, heading: "A", tree: Self.tree, branch: true)
        #expect(state.isOpen(note, heading: "A") && state.isOpen(note, heading: "A/A1"))
        // Closing the draft is remembered too.
        state.toggle(ProjectLayout.draft, tree: [], branch: false)
        #expect(!state.isOpen(ProjectLayout.draft))

        let again = OutlineState(projectRoot: root)
        #expect(again.isOpen(note, heading: "A/A1"))
        #expect(!again.isOpen(ProjectLayout.draft))
        // Renamed notes keep their state.
        again.move(note, to: "universe/characters/juno-hale.md")
        #expect(again.isOpen("universe/characters/juno-hale.md", heading: "A"))
        #expect(!again.isOpen(note))
        again.collapseAll("universe/characters/juno-hale.md")
        #expect(!again.isOpen("universe/characters/juno-hale.md"))
        again.expandAll(note, tree: Self.tree)
        #expect(HeadingTree.rows(Self.tree, isOpen: { again.isOpen(note, heading: $0) }).count == 4)
    }

    @Test func clickingAHeadingJumps() throws {
        let h = try SessionHarness()
        let session = h.session
        let note = try #require(session.links.graph.notes.first { !$0.headings.isEmpty })
        let heading = try #require(note.headings.last)
        session.area = .script
        session.open(heading: heading, in: note.path)
        #expect(session.area == .universe)
        #expect(session.universeSelection == note.path)
        #expect(session.noteReveal?.location == heading.range.location)
    }
}
