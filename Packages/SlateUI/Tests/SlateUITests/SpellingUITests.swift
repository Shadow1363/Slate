import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@Suite("Spelling tab, reveal and find")
@MainActor
struct SpellingUITests {
    private let note = "universe/rules/powers.md"
    private let actFile = "script/script.md"

    private func words(_ session: ProjectSession) -> [String] { session.spelling.issues.map(\.word) }

    private func scan(_ h: SessionHarness, _ path: String, text: String) throws {
        try h.store.document(at: path).text = text
        h.session.dictionary.refresh()
        h.session.spelling.scan(path: path, session: h.session)
    }

    // MARK: - Scanning

    @Test func countsRepeatsAndShowsContext() throws {
        let h = try SessionHarness()
        try scan(h, note, text: "# Notes\n\nShe found a qwzxv in the drawer. Then another qwzxv.\n")
        let issue = try #require(h.session.spelling.issues.first { $0.word == "qwzxv" })
        #expect(issue.count == 2)
        #expect(issue.context == "She found a qwzxv in the drawer. Then another qwzxv.")
        #expect((issue.context as NSString).substring(with: issue.contextRange) == "qwzxv")
    }

    @Test func neverFlagsNamesTermsLinksOrCode() throws {
        let h = try SessionHarness()
        // Mara Voss is a character note; Chronoshift is in the sample's word book.
        try scan(h, note, text: "Mara Voss can Chronoshift. See [[Zzyqqa Note]] and `kzzqvx()` but not flurbish.\n")
        #expect(words(h.session) == ["flurbish"])
    }

    @Test func scriptSkipsSceneIDsScreenplayTermsAndCharacters() throws {
        let h = try SessionHarness()
        try scan(h, actFile, text: """
            INT. KITCHEN - NIGHT {#s014}

            MARA (V.O.)
            Glorbix again.

            MARA (CONT'D)
            Still glorbix.

            """)
        #expect(words(h.session) == ["Glorbix", "glorbix"])
        #expect(SpellingScan.kind(for: actFile, text: "") == .script)
    }

    @Test func noteFrontmatterIsSkippedWhereTheEditorHidesIt() throws {
        let h = try SessionHarness()
        try scan(h, note, text: "---\ntype: rule\nname: Zzqbrt\n---\n\nPlain body.\n")
        #expect(words(h.session).isEmpty)
        try scan(h, ProjectLayout.draft, text: "---\nname: Zzqbrt\n---\n\nPlain body.\n")
        #expect(words(h.session) == ["Zzqbrt"])
    }

    @Test func spellingPathFollowsTheOpenFile() throws {
        let h = try SessionHarness()
        let session = h.session
        session.area = .universe
        session.universeSelection = note
        #expect(session.spellingPath == note)
        session.universeSelection = "universe/canvases/act-two.canvas"
        #expect(session.spellingPath == nil)
        session.area = .dictionary
        session.showingWordBookSource = false
        #expect(session.spellingPath == nil)
        session.showingWordBookSource = true
        #expect(session.spellingPath == WordBook.path)
        session.area = .storyboard
        #expect(session.spellingPath == nil)
    }

    // MARK: - Actions

    @Test func ignoreAndLearnClearTheWord() throws {
        let h = try SessionHarness()
        let text = "A qwzxv and a flurbish.\n"
        try scan(h, note, text: text)
        #expect(Set(words(h.session)) == ["qwzxv", "flurbish"])

        h.session.dictionary.ignore("qwzxv")
        h.session.spelling.scan(path: note, session: h.session)
        #expect(words(h.session) == ["flurbish"])

        h.session.dictionary.learn("flurbish", global: false)
        h.session.dictionary.refresh()
        h.session.spelling.scan(path: note, session: h.session)
        #expect(words(h.session).isEmpty)
        #expect(try h.store.readText(at: WordBook.path).contains("flurbish"))
        // The editors get the same list, on the same tag.
        let spelling = h.session.noteSpelling
        #expect(spelling.ignoredWords.contains("qwzxv"))
        #expect(spelling.documentTag == h.session.dictionary.spellTag)
        #expect(h.session.script.spelling.documentTag == h.session.dictionary.spellTag)
    }

    @Test func replaceOneThenAll() throws {
        let h = try SessionHarness()
        try scan(h, note, text: "qwzxv one, qwzxv two, qwzxv three.\n")
        var issue = try #require(h.session.spelling.issues.first)
        // Clicking the row twice shows the second; a suggestion replaces that one.
        _ = h.session.spelling.nextOccurrence(of: issue)
        _ = h.session.spelling.nextOccurrence(of: issue)
        h.session.spelling.replace(issue, with: "box", all: false, session: h.session)
        #expect(try h.store.readText(at: note) == "qwzxv one, box two, qwzxv three.\n")

        issue = try #require(h.session.spelling.issues.first)
        #expect(issue.count == 2)
        h.session.spelling.replace(issue, with: "box", all: true, session: h.session)
        #expect(try h.store.readText(at: note) == "box one, box two, box three.\n")
        #expect(words(h.session).isEmpty)
    }

    @Test func replaceRefusesTextThatMoved() throws {
        let h = try SessionHarness()
        try scan(h, note, text: "qwzxv here.\n")
        let issue = try #require(h.session.spelling.issues.first)
        try h.store.document(at: note).text = "Moved: qwzxv here.\n"
        h.session.spelling.replace(issue, with: "box", all: false, session: h.session)
        #expect(try h.store.readText(at: note) == "Moved: qwzxv here.\n")
        #expect(h.session.spelling.error != nil)
    }

    @Test func clickingWrapsRoundOccurrences() throws {
        let h = try SessionHarness()
        try scan(h, note, text: "qwzxv a qwzxv\n")
        let issue = try #require(h.session.spelling.issues.first)
        let model = h.session.spelling
        #expect(model.nextOccurrence(of: issue)?.location == 0)
        #expect(model.nextOccurrence(of: issue)?.location == 8)
        #expect(model.nextOccurrence(of: issue)?.location == 0)
    }

    // MARK: - Reveal

    @Test func openWithRangeCarriesTheLength() throws {
        let session = try SessionHarness().session
        session.open(note, range: NSRange(location: 10, length: 4))
        #expect(session.noteReveal?.location == 10)
        #expect(session.noteReveal?.length == 4)
        session.open(actFile, range: NSRange(location: 30, length: 5))
        #expect(session.area == .script)
        #expect(session.script.reveal?.location == 30)
        #expect(session.script.reveal?.length == 5)
    }

    @Test func markdownRevealSelectsTheRange() throws {
        let m = try MarkdownHarness(path: note, hidesFrontmatter: false)
        let reveal = RevealRequest(file: note, location: 5, focus: false, length: 4)
        m.controller.update(from: MarkdownEditor(document: m.document, text: m.document.text, hidesFrontmatter: false,
                                                 theme: ThemeEngine.builtInLight, reveal: reveal,
                                                 linkVersion: m.harness.session.links.version, session: m.harness.session,
                                                 spelling: m.harness.session.noteSpelling))
        #expect(m.textView.selectedRange() == NSRange(location: 5, length: 4))
    }

    @Test func revealCentresTheRange() {
        TextReveal.reduceMotionOverride = true
        defer { TextReveal.reduceMotionOverride = nil }
        let (scrollView, textView) = SlateTextView.scrollable()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView.string = (1...300).map { "Line \($0)" }.joined(separator: "\n")
        // Without a window the view doesn't grow with its text; size it as the editor would.
        textView.frame.size.height = 6000
        let target = (textView.string as NSString).range(of: "Line 150")
        textView.reveal(range: target, focus: false)
        #expect(textView.selectedRange() == target)
        let clip = scrollView.contentView
        let rect = textView.convert(textView.boundingRect(of: target) ?? .zero, to: clip)
        #expect(abs(rect.midY - clip.bounds.midY) < 2)
        // Near the top it can't centre past the start.
        textView.reveal(range: NSRange(location: 0, length: 4), focus: false)
        #expect(clip.bounds.origin.y == 0)
    }

    // MARK: - Find and the search field

    @Test func findTargetFollowsTheView() throws {
        let session = try SessionHarness().session
        session.area = .script
        session.script.showingPages = false
        #expect(session.findTarget == .editor)
        session.script.showingPages = true
        #expect(session.findTarget == nil)
        session.area = .storyboard
        #expect(session.findTarget == .filter)
        session.area = .dictionary
        session.showingWordBookSource = false
        #expect(session.findTarget == .filter)
        session.area = .universe
        session.universeSelection = note
        #expect(session.findTarget == .editor)
        session.universeSelection = "universe/canvases/act-two.canvas"
        #expect(session.findTarget == .filter)
        session.universeSelection = "universe/maps/city.map.json"
        #expect(session.findTarget == nil)
        let before = session.filterFocusRequest
        session.focusFilter()
        #expect(session.filterFocusRequest == before)
    }

    @Test func findKeysAreReserved() {
        for key in ["cmd+f", "cmd+opt+f", "cmd+g", "cmd+shift+g", "cmd+e"] {
            #expect(Shortcuts.clash(key, excluding: "dictate", overrides: [:], search: "cmd+k") != nil)
        }
        #expect(Shortcuts.clash("cmd+shift+f", excluding: "searchText", overrides: [:], search: "cmd+k") == nil)
    }

    @Test func storyboardAndCanvasFilters() throws {
        let h = try SessionHarness()
        let board = h.session.storyboard
        let rows = board.rows
        let kitchen = try #require(rows.first { $0.title.contains("KITCHEN") })
        board.sceneFilter = "kitchen"
        #expect(board.matchesFilter(kitchen))
        board.sceneFilter = "zzz-nothing"
        #expect(!board.matchesFilter(kitchen))
        board.sceneFilter = ""
        #expect(board.matchesFilter(kitchen))
    }

    @Test func textSearchKeepsItsPrefix() throws {
        let session = try SessionHarness().session
        let search = SpotlightModel(session: session, query: "!text ")
        #expect(search.query == "!text ")
        // ⇧⌘F with Search already open puts the prefix back, caret after it.
        search.replaceQuery(with: "!text ")
        #expect(search.queryReplaced == 1)
        search.query = "!c"
        search.complete(with: "!cue")
        #expect(search.query == "!cue ")
        #expect(search.queryReplaced == 2)
    }
}
