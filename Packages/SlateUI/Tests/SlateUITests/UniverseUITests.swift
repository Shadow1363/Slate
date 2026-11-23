import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

/// A copy of the sample project with a session, for driving the Universe UI.
@MainActor
final class SessionHarness {
    let folder: URL
    let store: ProjectStore
    let session: ProjectSession

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "SlateUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sample = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/SampleProject", directoryHint: .isDirectory)
        let root = folder.appending(path: "SampleProject", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: sample, to: root)
        store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        // Never the real global word book.
        session = ProjectSession(store: store, globalWordsURL: folder.appending(path: "global-words.md"))
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: store.rootURL.appending(path: path), encoding: .utf8)
    }
}

/// The Markdown editor controller without a window.
@MainActor
final class MarkdownHarness {
    let harness: SessionHarness
    let document: TextDocument
    let controller = MarkdownEditorController()
    let hidesFrontmatter: Bool
    private var scrollView: NSScrollView?

    init(path: String, hidesFrontmatter: Bool) throws {
        harness = try SessionHarness()
        document = try harness.store.document(at: path)
        self.hidesFrontmatter = hidesFrontmatter
        scrollView = controller.makeView(for: editor())
        controller.update(from: editor())
    }

    func editor() -> MarkdownEditor {
        MarkdownEditor(document: document, text: document.text, hidesFrontmatter: hidesFrontmatter, theme: ThemeEngine.builtInLight,
                       reveal: nil, linkVersion: harness.session.links.version, session: harness.session,
                       spelling: harness.session.noteSpelling)
    }

    var textView: NSTextView { controller.textView }

    func type(_ string: String) {
        for character in string {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
            controller.update(from: editor())
        }
    }

    func press(_ selector: Selector) {
        textView.doCommand(by: selector)
        controller.update(from: editor())
    }

    func moveToEnd() {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }
}

@Suite("Markdown editor")
@MainActor
struct MarkdownEditorTests {
    @Test func editsOnlyTheBodyOfANote() throws {
        let h = try MarkdownHarness(path: "universe/characters/mara-voss.md", hidesFrontmatter: true)
        #expect(h.textView.string.hasPrefix("## Want"))
        h.moveToEnd()
        h.type("\nMore.")
        #expect(h.document.text.hasPrefix("---\ntype: character\nid: c-7f3a\n"))
        #expect(h.document.text.hasSuffix("[[The Brass Key]].\n\nMore."))
    }

    @Test func linkAutocompleteInsertsTheName() throws {
        let h = try MarkdownHarness(path: "universe/draft.md", hidesFrontmatter: false)
        h.moveToEnd()
        h.type("\nAsk [[")
        h.type("The S")
        #expect(h.controller.completion.items.map(\.text) == ["The Station"])
        h.press(#selector(NSResponder.insertNewline(_:)))
        #expect(h.document.text.hasSuffix("Ask [[The Station]]"))
        #expect(!h.controller.completion.isActive)
    }

    @Test func arrowsChooseAndEscDismisses() throws {
        let h = try MarkdownHarness(path: "universe/draft.md", hidesFrontmatter: false)
        h.moveToEnd()
        h.type("\n[[The")
        #expect(h.controller.completion.items.count == 4)
        h.press(#selector(NSResponder.moveDown(_:)))
        #expect(h.controller.completion.selection == 1)
        h.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(!h.controller.completion.isActive)
        h.type(" ")
        #expect(!h.controller.completion.isActive) // Stays dismissed for this link.
    }

    @Test func insertLinkCommandOpensTheList() throws {
        let h = try MarkdownHarness(path: "universe/draft.md", hidesFrontmatter: false)
        h.moveToEnd()
        h.controller.completion.insertLink(in: h.textView)
        h.controller.update(from: h.editor())
        #expect(h.document.text.hasSuffix("[[]]"))
        #expect(h.controller.completion.items.count == 8) // names first, up to the panel limit
        h.type("loop")
        h.press(#selector(NSResponder.insertTab(_:)))
        #expect(h.document.text.hasSuffix("[[Loop Rules]]"))
    }

    @Test func listsContinueOnReturn() throws {
        let h = try MarkdownHarness(path: "universe/draft.md", hidesFrontmatter: false)
        h.moveToEnd()
        h.type("\n- one")
        h.press(#selector(NSResponder.insertNewline(_:)))
        h.type("two")
        h.press(#selector(NSResponder.insertNewline(_:)))
        h.press(#selector(NSResponder.insertNewline(_:)))
        #expect(h.document.text.hasSuffix("- one\n- two\n"))
    }

    @Test func linksCarryTheirTargetAndResolvedState() throws {
        let h = try MarkdownHarness(path: "universe/rules/time-travel.md", hidesFrontmatter: true)
        let storage = try #require(h.textView.textStorage)
        let body = h.textView.string as NSString
        let archivist = body.range(of: "[[The Archivist]]")
        #expect(storage.attribute(.slateLinkTarget, at: archivist.location + 3, effectiveRange: nil) as? String == "The Archivist")
        #expect(storage.attribute(.underlineStyle, at: archivist.location + 3, effectiveRange: nil) != nil)
    }

    @Test func outsideChangesReloadTheBody() throws {
        let h = try MarkdownHarness(path: "universe/characters/mara-voss.md", hidesFrontmatter: true)
        h.document.text = h.document.text.replacingOccurrences(of: "To undo", with: "To redo")
        h.controller.update(from: h.editor())
        #expect(h.textView.string.contains("To redo"))
    }
}

@Suite("Universe session")
@MainActor
struct UniverseSessionTests {
    @Test func formEditsChangeOnlyThatLine() throws {
        let h = try SessionHarness()
        let document = try h.store.document(at: "universe/rules/time-travel.md")
        let before = document.text
        document.text = Frontmatter.setting("summary", to: .string("Only nights you lived."), in: document.text)
        h.store.save(document)
        let after = try h.read("universe/rules/time-travel.md")
        #expect(after == before.replacingOccurrences(of: "summary: You can only go back to a night you already lived.", with: "summary: Only nights you lived."))
        #expect(after.contains("# Written by hand: this comment should survive form edits."))
    }

    @Test func createsNotesFromTemplatesAndFollowsLinks() throws {
        let h = try SessionHarness()
        let session = h.session
        #expect(session.followLink("The Courier"))
        #expect(session.area == .universe)
        #expect(session.universeSelection == "universe/characters/mara-voss.md")

        session.followLink("The Archivist")
        guard case .newNote(_, let name) = session.sheet else {
            Issue.record("Expected the New Note sheet")
            return
        }
        #expect(name == "The Archivist")
        let character = try #require(session.templates.first { $0.type == "character" })
        #expect(character.origin == .project)
        let path = try session.createNote(template: character, name: name)
        #expect(path == "universe/characters/the-archivist.md")
        // Only the sample timeline's "The Archive" (no note, on purpose) is left.
        #expect(session.links.graph.unresolved.map(\.link.target) == ["The Archive"])
        #expect(try h.read(path).contains("first appearance:"))
    }

    @Test func renameUpdatesLinksAndSelection() throws {
        let h = try SessionHarness()
        let session = h.session
        session.universeSelection = "universe/locations/the-station.md"
        let plan = try #require(session.renamePlan(for: "universe/locations/the-station.md", to: "Grand Station"))
        #expect(plan.edits.count == 4) // the brass key, powers, the dictionary and a timeline event's location
        session.rename(plan, updateLinks: true)
        #expect(session.dictionary.entry(for: "Chronoshift")?.links.map(\.target).contains("Grand Station") == true)
        #expect(session.universeSelection == "universe/locations/grand-station.md")
        #expect(try h.read("universe/items/the-brass-key.md").contains("[[Grand Station]]"))
        #expect(try h.read("universe/timelines/main.timeline.json").contains("\"location\": \"Grand Station\""))
        #expect(session.links.graph.resolve("Grand Station")?.path == "universe/locations/grand-station.md")
    }

    @Test func searchResultsAndQuickOpenNavigate() throws {
        let h = try SessionHarness()
        let session = h.session
        session.open("script/script.md", location: 10)
        #expect(session.area == .script)
        #expect(session.script.reveal?.location == 10)

        let search = SpotlightModel(session: session, query: "kitchen")
        let first = try #require(search.flatResults.first)
        #expect(first.scope == .scene)
        search.open(first)
        #expect(session.script.selectedRow == "scene:s014")

        search.query = "brass"
        search.open(try #require(search.flatResults.first))
        #expect(session.universeSelection == "universe/items/the-brass-key.md")
    }

    @Test func draftHeadingBecomesASceneStub() throws {
        let h = try SessionHarness()
        let path = h.session.script.appendSceneStub(heading: "Act one")
        #expect(path == "script/script.md")
        let text = try #require(h.store.documents["script/script.md"]).text
        #expect(text.hasSuffix("CUT TO:\n\n.ACT ONE {#s015}\n"))
    }

    @Test func scriptLinksAreFollowable() throws {
        let h = try EditorHarness(text: "INT. ROOM {#s001}\n\nShe holds [[Key]].\n")
        h.workspace.followLink = { $0 == "Key" }
        let storage = try #require(h.textView.textStorage)
        let location = (h.text as NSString).range(of: "[[Key]]").location + 2
        #expect(storage.attribute(.slateLinkTarget, at: location, effectiveRange: nil) as? String == "Key")
    }
}
