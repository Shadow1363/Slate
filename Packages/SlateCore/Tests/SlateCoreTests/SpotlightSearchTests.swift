import Foundation
import Testing
@testable import SlateCore

@Suite("Search: bangs, tags and filters")
struct SpotlightSearchTests {
    static let bangs = Bangs.all(templates: NoteTemplates.builtIn)

    static func query(_ text: String) -> SearchQuery { SearchQuery.parse(text, bangs: bangs) }

    @Test func bangsForTemplatesAndAreas() {
        let names = Dictionary(Self.bangs.map { ($0.scope.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        #expect(names["template:character"] == "c")
        #expect(names["template:location"] == "l")
        #expect(names["template:note"] == "n")
        #expect(names["scene"] == "s")
        #expect(names["cue"] == "cue")
        // A new template gets its first free letters; s is taken by scenes.
        let ship = NoteTemplate(type: "ship", label: "Ship", folder: "ships", fields: [], origin: .project)
        let more = Bangs.all(templates: NoteTemplates.builtIn + [ship])
        #expect(more.first { $0.scope == .template("ship") }?.name == "sh")
        // A template's own bang wins over an area's.
        var spell = ship
        spell.bang = "s"
        let claimed = Bangs.all(templates: [spell])
        #expect(claimed.first { $0.name == "s" }?.scope == .template("ship"))
        #expect(!claimed.contains { $0.scope == .scene })
        #expect(Bangs.clashes(templates: [spell], renames: [:]) == ["s"])
        // Renamed areas.
        let renamed = Bangs.all(templates: [], renames: ["scene": "sc"])
        #expect(renamed.first { $0.scope == .scene }?.name == "sc")
    }

    @Test func parsingQueries() {
        var q = Self.query("!c juno")
        #expect(q.scopes == [.template("character")])
        #expect(q.text == "juno")
        q = Self.query("juno !c")
        #expect(q.scopes == [.template("character")] && q.text == "juno")
        q = Self.query("!c !l harbour #Good role:lead int: \"always empty\"")
        #expect(q.scopes == [.template("character"), .template("location")])
        #expect(q.tags == ["good"])
        #expect(q.filters == [.init(key: "role", value: "lead"), .init(key: "int", value: "")])
        #expect(q.exact == ["always empty"])
        #expect(q.text == "harbour")
        q = Self.query("!t good protagonist")
        #expect(q.scopes == [.tag] && q.tags == ["good", "protagonist"] && q.text.isEmpty)
        q = Self.query("/always")
        #expect(q.scopes == [.text] && q.text == "always")
        q = Self.query("!film slack !s storm")
        #expect(q.scopes == [.film, .scene])
        #expect(q.filters == [.init(key: "film", value: "slack")])
        #expect(q.text == "storm")
        // Unknown bangs are words; the one being typed is a suggestion.
        q = Self.query("!zz kitchen")
        #expect(q.scopes.isEmpty && q.text == "!zz kitchen")
        q = Self.query("!cu")
        #expect(q.partial == "!cu")
        #expect(SearchEngine.suggestions(for: "!cu", bangs: Self.bangs).first?.name == "cue")
    }

    static let act = """
    # ACT ONE

    EXT. HARBOUR - NIGHT {#s001 color=red tags=storm,1987}

    Rain.

    JUNO
    It's always empty.

    TOBIAS
    (quietly)
    The sea keeps what it's owed.

    CUT TO:

    INT. LIGHTHOUSE - DAY {#s002 tags=quiet}

    JUNO
    Morning.
    """

    @Test func sceneTagsParseAndNeverPrint() {
        let parsed = ScriptParser.parse(Self.act)
        #expect(parsed.scenes.map(\.tags) == [["storm", "1987"], ["quiet"]])
        let page = Paginator().paginate([parsed]).pages[0]
        #expect(!page.rows.contains { $0.line.text.contains("tags") || $0.line.text.contains("storm") })
        // Renaming a tag in the script, and removing one.
        let renamed = Tags.renaming("storm", to: "Big Storm", inScript: Self.act)
        #expect(renamed.contains("{#s001 color=red tags=big-storm,1987}"))
        let removed = Tags.renaming("quiet", to: nil, inScript: renamed)
        #expect(removed.contains("INT. LIGHTHOUSE - DAY {#s002}"))
    }

    @Test func scenesSpeechesAndFilters() {
        let book = ScriptBook(texts: [(path: "script/01 T/01-act-one.md", text: Self.act)])
        let items = SearchItems.script(book, film: "Tidewater", filmNumber: 1)
        func titles(_ text: String) -> [String] {
            SearchEngine.search(Self.query(text), in: items).flatMap(\.items).map(\.title)
        }
        #expect(titles("!s") == ["EXT. HARBOUR - NIGHT", "INT. LIGHTHOUSE - DAY"])
        #expect(titles("!s time:night") == ["EXT. HARBOUR - NIGHT"])
        #expect(titles("!s int:") == ["INT. LIGHTHOUSE - DAY"])
        #expect(titles("!s ext:") == ["EXT. HARBOUR - NIGHT"])
        #expect(titles("!s color:red") == ["EXT. HARBOUR - NIGHT"])
        #expect(titles("!s #storm") == ["EXT. HARBOUR - NIGHT"])
        #expect(titles("!s film:1").count == 2)
        #expect(titles("!s film:2").isEmpty)
        #expect(titles("!film tide !s").count == 2)
        #expect(titles("!cue juno") == ["It's always empty.", "Morning."])
        #expect(titles("!cue juno empty") == ["It's always empty."])
        #expect(titles("!cue tobias") == ["The sea keeps what it's owed."])
        #expect(titles("!x") == ["CUT TO:"])
        #expect(titles("!act") == ["01-act-one.md", "ACT ONE"])
        // A plain search finds scenes by name, not every line.
        #expect(titles("harbour") == ["EXT. HARBOUR - NIGHT"])
    }

    @Test func tagsAcrossNotesAndScenes() throws {
        let juno = Note(path: "universe/characters/juno.md", text: "---\ntype: character\nname: Juno\nrole: lead\ntags: [Protagonist, good]\n---\n")
        let ida = Note(path: "universe/characters/ida.md", text: "---\ntype: character\nname: Ida\ntags: [antagonist]\n---\n")
        let tobias = Note(path: "universe/characters/tobias.md", text: "---\ntype: character\nname: Tobias\ntags: [good, mentor]\n---\n")
        let harbour = Note(path: "universe/locations/harbour.md", text: "---\ntype: location\nname: Harbour\ntags: [good]\n---\n")
        let templates = NoteTemplates.builtIn
        let notes = [juno, ida, tobias, harbour]
        let parsed = ScriptParser.parse(Self.act)
        let index = TagIndex(notes: notes, scenes: parsed.scenes.map { ($0.sceneID!, $0.heading, nil, $0.tags) })
        #expect(index.count("good") == 3)
        #expect(index.tags.first?.tag == "good")

        var items = notes.map { note in SearchItems.note(note, template: templates.first { $0.type == note.type }) }
        items += SearchItems.script(ScriptBook(texts: [(path: "script/a.md", text: Self.act)]), film: nil, filmNumber: 1)
        items += SearchItems.tags(index)
        func titles(_ text: String) -> [String] {
            SearchEngine.search(Self.query(text), in: items).flatMap(\.items).map(\.title)
        }
        #expect(titles("!t good protagonist") == ["Juno"])
        #expect(titles("!t good") == ["Juno", "Tobias", "Harbour"])
        #expect(titles("!c #good") == ["Juno", "Tobias"])
        #expect(titles("#storm") == ["EXT. HARBOUR - NIGHT"])
        #expect(titles("!c role:lead") == ["Juno"])
        #expect(titles("!t").first == "#good")
        #expect(titles("!u").count == 4)
        #expect(titles("!l") == ["Harbour"])
        // Sections take the template's folder name.
        let sections = SearchEngine.search(Self.query("!u"), in: items)
        #expect(sections.map(\.title) == ["Characters", "Locations"])

        // Renaming a tag in a note.
        let text = "---\ntype: character\nname: Juno\ntags: [protagonist, good]\n---\nBody\n"
        let renamed = Tags.renaming("good", to: "Kind Hearted", inNote: text, path: juno.path)
        #expect(renamed.contains("tags: [protagonist, kind-hearted]"))
        #expect(Tags.renaming("missing", to: "x", inNote: text, path: juno.path) == text)
        #expect(Tags.normalize("#Good Guy") == "good-guy")
        #expect(Tags.parseList("storm, Flash Back,storm") == ["storm", "flash-back"])
    }

    @Test func doneTodosAndDueDates() {
        let items = [
            SearchItem(scope: .todo, group: "To-dos", title: "Late", icon: "checkmark", target: .todo(line: 1, sceneID: nil, quote: nil),
                       fields: ["done": "no", "due": "2026-12-01"]),
            SearchItem(scope: .todo, group: "To-dos", title: "Soon", icon: "checkmark", target: .todo(line: 2, sceneID: nil, quote: nil),
                       fields: ["done": "no", "due": "2026-11-25"]),
            SearchItem(scope: .todo, group: "To-dos", title: "Done", icon: "checkmark", target: .todo(line: 3, sceneID: nil, quote: nil),
                       fields: ["done": "yes"]),
        ]
        func titles(_ text: String) -> [String] { SearchEngine.search(Self.query(text), in: items).flatMap(\.items).map(\.title) }
        #expect(titles("!todo") == ["Late", "Soon"])
        #expect(titles("!todo due:") == ["Soon", "Late"])
        #expect(titles("!todo done:") == ["Done"])
    }

    @Test func templateBangRoundTrips() throws {
        var template = try #require(NoteTemplates.builtIn.first { $0.type == "faction" })
        template.bang = "fa"
        let read = try NoteTemplate(text: template.text, fileName: "faction.md", origin: .project)
        #expect(read.bang == "fa")
    }
}
