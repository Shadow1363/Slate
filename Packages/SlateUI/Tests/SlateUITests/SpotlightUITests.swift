import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Search (⌘K), tags and the optional draft")
struct SpotlightUITests {
    private func titles(_ search: SpotlightModel) -> [String] { search.flatResults.map(\.title) }

    @Test func bangsSearchEachArea() throws {
        let h = try SessionHarness()
        let search = SpotlightModel(session: h.session)
        search.query = "!c"
        #expect(Set(titles(search)) == ["Mara Voss", "Thomas Wiley Cade"])
        search.query = "!c mara"
        #expect(titles(search).first == "Mara Voss")
        search.query = "!r"
        #expect(titles(search).count == 2)
        search.query = "!s"
        #expect(titles(search).contains("INT. KITCHEN - NIGHT"))
        search.query = "!cue older"
        #expect(titles(search) == ["You already have."])
        search.query = "!tl fire"
        // "No fire" is a branch, not an event.
        #expect(Set(titles(search)) == ["Station fire", "The fire never starts"])
        search.query = "!m station"
        #expect(titles(search).contains("The Station"))
        search.query = "!w chrono"
        #expect(titles(search) == ["Chronoshift"])
        search.query = "!todo due:"
        #expect(titles(search).first == "Fix Mara's motivation before the reveal")
        search.query = "!b"
        #expect(!titles(search).isEmpty)
        search.query = "!d"
        #expect(search.flatResults.allSatisfy { $0.scope == .draft })
        // Bang suggestions while typing.
        search.query = "!c"
        search.query = "!cu"
        #expect(search.bangSuggestions.first?.name == "cue")
        search.query = "!"
        #expect(search.bangSuggestions.count == search.bangs.count)
    }

    @Test func resultsOpenInTheRightPlace() throws {
        let h = try SessionHarness()
        let session = h.session
        let search = SpotlightModel(session: session)
        search.query = "!w chrono"
        search.open(try #require(search.flatResults.first))
        #expect(session.area == .dictionary)
        #expect(session.dictionarySelection != nil)

        search.query = "!tl station fire"
        search.open(try #require(search.flatResults.first))
        #expect(session.area == .universe)
        #expect(session.universeSelection == "universe/timelines/main.timeline.json")
        #expect(session.pendingItemSelection?.path == "universe/timelines/main.timeline.json")

        search.query = "!m station"
        let place = try #require(search.flatResults.first { $0.title == "The Station" })
        search.open(place)
        #expect(session.mapReveal?.path == "universe/maps/city.map.json")

        search.query = "!cue older"
        search.open(try #require(search.flatResults.first))
        #expect(session.area == .script)
        #expect(session.script.reveal?.file == "script/script.md")

        // Picking a tag drills in instead of closing.
        search.query = "!t"
        let tag = try #require(search.flatResults.first { $0.title == "#lead" })
        #expect(search.open(tag) == false)
        #expect(search.query.hasPrefix("!t lead"))
        #expect(titles(search) == ["Mara Voss"])
        #expect(search.recentSearches.first != nil)
    }

    @Test func tagsOnNotesAndScenes() throws {
        let h = try SessionHarness()
        let session = h.session
        session.setTags(["lead", "good"], forNote: "universe/characters/mara-voss.md")
        #expect(try h.read("universe/characters/mara-voss.md").contains("tags: [lead, good]"))
        let scene = try #require(session.script.scene(withID: "s014"))
        session.script.setTags(["night", "Storm Front"], for: scene)
        #expect(session.script.scene(withID: "s014")?.scene.tags == ["night", "storm-front"])
        #expect(session.knownTags.contains("storm-front"))

        let search = SpotlightModel(session: session)
        search.query = "!t good"
        #expect(titles(search) == ["Mara Voss"])
        search.query = "#storm-front"
        #expect(titles(search) == ["INT. KITCHEN - NIGHT"])
        search.query = "#sto"
        #expect(search.tagSuggestions.first?.tag == "storm-front")

        // Renaming a tag everywhere, then removing one.
        #expect(session.renameTag("good", to: "kind") == 1)
        #expect(try h.read("universe/characters/mara-voss.md").contains("tags: [lead, kind]"))
        session.store.saveAll()
        #expect(session.renameTag("night", to: nil) == 1)
        #expect(session.script.scene(withID: "s014")?.scene.tags == ["storm-front"])
    }

    @Test func theRoughDraftIsOptional() throws {
        let h = try SessionHarness()
        let session = h.session
        #expect(session.universeSelection == ProjectLayout.draft)
        session.trash(ProjectLayout.draft)
        #expect(!session.exists(ProjectLayout.draft))
        #expect(session.universeSelection == nil)
        // Search no longer offers its headings, and a fresh session starts with nothing selected.
        let search = SpotlightModel(session: session, query: "!d")
        #expect(search.flatResults.isEmpty)
        let reopened = ProjectSession(store: h.store, globalWordsURL: h.folder.appending(path: "global-words.md"))
        #expect(reopened.universeSelection == nil)

        session.createDraft()
        #expect(session.exists(ProjectLayout.draft))
        #expect(try h.read(ProjectLayout.draft).hasPrefix("# "))
        #expect(session.universeSelection == ProjectLayout.draft)
    }

    @Test func theShortcutTogglesSearch() throws {
        let h = try SessionHarness()
        let session = h.session
        session.showSearch()
        #expect(session.spotlight != nil)
        session.showSearch() // pressed again
        #expect(session.spotlight == nil)
        // A query (⇧⌘F, a tag in the sidebar) opens it, or retypes it if open.
        session.showSearch("!text ")
        #expect(session.spotlight?.query == "!text ")
        session.showSearch("!t storm ")
        #expect(session.spotlight?.query == "!t storm ")
        session.closeSearch()
        #expect(session.spotlight == nil)
    }

    @Test func shortcutsParseAndClash() throws {
        let k = try #require(SearchShortcut("cmd+k"))
        #expect(k.display == "⌘K")
        #expect(k.clash == nil)
        #expect(SearchShortcut("cmd+shift+space")?.display == "⇧⌘Space")
        #expect(SearchShortcut("k") == nil) // needs ⌘ or ⌃
        #expect(SearchShortcut("cmd+s")?.clash == "Save")
        #expect(SearchShortcut("ctrl+opt+f")?.text == "ctrl+opt+f")
    }
}
