import Foundation
import Testing
@testable import SlateCore

@Suite("Frontmatter")
struct FrontmatterTests {
    let mara = """
    ---
    type: character
    id: c-7f3a
    # the lead
    name: Mara Voss
    aliases: [Mara, The Courier]
    age: 34
    tags:
      - lead
      - "pov"
    ---
    ## Want
    To undo the night.

    """

    @Test func parsesFieldsInOrder() throws {
        let fields = try Frontmatter.fields(in: mara)
        #expect(fields.map(\.key) == ["type", "id", "name", "aliases", "age", "tags"])
        #expect(fields[2].value == .string("Mara Voss"))
        #expect(fields[3].value.items == ["Mara", "The Courier"])
        #expect(fields[4].value == .int(34))
        #expect(fields[5].value.items == ["lead", "pov"])
    }

    @Test func splitsBody() {
        let split = Frontmatter.split(mara)
        #expect(split.body == "## Want\nTo undo the night.\n")
        #expect((mara as NSString).substring(from: split.bodyOffset) == split.body)
        #expect(Frontmatter.split("# Just a body\n") == .init(yaml: nil, body: "# Just a body\n", bodyOffset: 0))
    }

    @Test func settingChangesOnlyThatLine() {
        let edited = Frontmatter.setting("age", to: .int(35), in: mara)
        #expect(edited == mara.replacingOccurrences(of: "age: 34", with: "age: 35"))
    }

    @Test func settingAMultiLineValueReplacesAllItsLines() {
        let edited = Frontmatter.setting("tags", to: .list([.string("lead")]), in: mara)
        #expect(edited.contains("tags: [lead]\n---"))
        #expect(!edited.contains("- lead"))
        #expect(edited.contains("# the lead"))
    }

    @Test func newKeysGoAtTheEndAndRemovalIsSurgical() throws {
        let added = Frontmatter.setting("role", to: .string("Courier: retired"), in: mara)
        #expect(added.contains("  - \"pov\"\nrole: \"Courier: retired\"\n---"))
        #expect(try Frontmatter.fields(in: added).last == YAMLField("role", .string("Courier: retired")))
        let removed = Frontmatter.removing("role", in: added)
        #expect(removed == mara)
    }

    @Test func unchangedValueIsByteIdentical() {
        #expect(Frontmatter.setting("name", to: .string("Mara Voss"), in: mara) == mara)
        #expect(Frontmatter.replacingBody(of: mara, with: Frontmatter.split(mara).body) == mara)
    }

    @Test func noteWithoutFrontmatterGetsABlock() throws {
        let edited = Frontmatter.setting("name", to: .string("Kitchen"), in: "Body\n")
        #expect(edited == "---\nname: Kitchen\n---\nBody\n")
        #expect(try Frontmatter.fields(in: edited) == [YAMLField("name", .string("Kitchen"))])
    }

    @Test func quotesOnlyWhenNeeded() {
        #expect(Frontmatter.emit(.string("Mara Voss")) == "Mara Voss")
        #expect(Frontmatter.emit(.string("[[Mara Voss]]")) == "\"[[Mara Voss]]\"")
        #expect(Frontmatter.emit(.string("yes")) == "\"yes\"")
        #expect(Frontmatter.emit(.string("34")) == "\"34\"")
        #expect(Frontmatter.emit(.string("a: b")) == "\"a: b\"")
        #expect(Frontmatter.emit(.string("say \"hi\"\n")) == "\"say \\\"hi\\\"\\n\"")
        #expect(Frontmatter.emit(.list([.string("a"), .string("b, c")])) == "[a, \"b, c\"]")
        for value in ["[[Mara Voss]]", "yes", "34", "a: b", "say \"hi\"\nthen", "#tag", "", " padded "] {
            let text = Frontmatter.setting("x", to: .string(value), in: "---\n---\n")
            #expect((try? Frontmatter.fields(in: text)) == [YAMLField("x", .string(value))], "round trip of \(value)")
        }
    }

    @Test func badYAMLThrowsAndKeepsTheText() {
        let broken = "---\nname: [unclosed\n---\nBody\n"
        #expect(throws: FrontmatterError.self) { try Frontmatter.fields(in: broken) }
        let note = Note(path: "universe/x.md", text: broken)
        #expect(note.frontmatterError != nil)
        #expect(note.name == "x")
    }

    @Test func datesStayStrings() throws {
        let fields = try Frontmatter.fields(in: "---\nwhen: 2031-03-14\n---\n")
        #expect(fields == [YAMLField("when", .string("2031-03-14"))])
    }
}

@Suite("Note templates")
struct NoteTemplateTests {
    @Test func builtInsLoad() {
        let types = NoteTemplates.builtIn.map(\.type)
        #expect(types == ["character", "location", "rule", "faction", "item", "event", "note"])
        let event = NoteTemplates.builtIn.first { $0.type == "event" }!
        #expect(event.fields.first { $0.key == "when" }?.label == "When (world time)")
        #expect(event.fields.first { $0.key == "where" }?.type == .link)
        #expect(event.folder == "events")
    }

    @Test func projectTemplatesOverrideBuiltIns() throws {
        let templates = NoteTemplates.load(projectTemplates: Fixtures.sampleProject.appending(path: "templates"), globalTemplates: nil)
        let character = try #require(templates.first { $0.type == "character" })
        #expect(character.origin == .project)
        #expect(character.fields.map(\.key).contains("first appearance"))
        #expect(character.body.contains("## Ghost"))
        #expect(templates.map(\.type).first == "character")
    }

    @Test func newNoteHasTypeIdNameAndEmptyFields() throws {
        let template = try #require(NoteTemplates.builtIn.first { $0.type == "item" })
        let text = template.newNote(name: "The Brass Key", id: "i-0001")
        #expect(text.hasPrefix("---\ntype: item\nid: i-0001\nname: The Brass Key\naliases: []\nowner:\nimage:\ntags: []\n---\n## What it is"))
        let note = Note(path: "universe/items/the-brass-key.md", text: text)
        #expect(note.name == "The Brass Key")
        #expect(note.noteID == "i-0001")
        #expect(note.frontmatterError == nil)
    }

    @Test func idsAndPaths() throws {
        let template = try #require(NoteTemplates.builtIn.first { $0.type == "character" })
        let id = template.newID(existing: [])
        #expect(id.wholeMatch(of: /c-[0-9a-f]{4}/) != nil)
        #expect(template.path(forName: "Mara Voss", existing: []) == "universe/characters/mara-voss.md")
        #expect(template.path(forName: "Mara Voss", existing: ["universe/characters/mara-voss.md"]) == "universe/characters/mara-voss-2.md")
        #expect(Slug.make("Élodie’s Café — 1998!") == "elodies-cafe-1998")
        #expect(Slug.make("???") == "untitled")
    }

    @Test func shorthandAndFullFieldDeclarations() throws {
        let template = try NoteTemplate(text: """
        ---
        type: ship
        fields:
          crew: number
          captain: {type: link, label: Captain}
          launched: date
          weird: {type: nonsense}
        ---
        """, fileName: "ship.md", origin: .project)
        #expect(template.folder == "ships")
        #expect(template.fields.map(\.key) == ["name", "crew", "captain", "launched", "weird"])
        #expect(template.fields.map(\.type) == [.text, .number, .link, .date, .text])
        #expect(template.idPrefix == "s")
    }
}

@Suite("Notes and links")
struct NoteTests {
    @Test func nameFallsBackToHeadingThenFileName() {
        #expect(Note(path: "universe/a.md", text: "---\nname: Named\n---\n# Heading\n").name == "Named")
        #expect(Note(path: "universe/a.md", text: "Intro\n\n# Heading\n").name == "Heading")
        #expect(Note(path: "universe/notes/loose-idea.md", text: "no heading").name == "loose-idea")
    }

    @Test func findsLinksWithShownTextAndHeadings() {
        let links = WikiLink.find(in: "See [[Mara Voss|her]] and [[ The Station#Fire ]] and [[]].")
        #expect(links.map(\.target) == ["Mara Voss", "The Station"])
        #expect(links[0].shown == "her")
        #expect(links[0].displayText == "her")
        #expect(links[1].heading == "Fire")
        let text = "See [[Mara Voss|her]] and [[ The Station#Fire ]] and [[]]." as NSString
        #expect(text.substring(with: links[1].targetRange) == "The Station")
    }

    @Test func skipsLinksInCode() {
        let text = """
        Real [[Mara]].

        ```
        [[Not A Link]]
        ```

        Inline `[[Nope]]` and ``[[Also `no`]]`` but [[Yes]].

            [[Indented code]]
        """
        let note = Note(path: "universe/n.md", text: text)
        #expect(note.links.map(\.target) == ["Mara", "Yes"])
    }

    @Test func headingsUseUnicodeSafeRanges() {
        let text = "---\nname: X\n---\n# Café ☕️\n\nBody\n\n## Zweite\n"
        let note = Note(path: "universe/x.md", text: text)
        #expect(note.headings.map(\.title) == ["Café ☕️", "Zweite"])
        #expect((text as NSString).substring(with: note.headings[1].range) == "## Zweite")
    }
}

@Suite("Link index")
struct LinkGraphTests {
    func sampleGraph() throws -> LinkGraph {
        let root = Fixtures.sampleProject
        let paths = [
            "universe/characters/mara-voss.md", "universe/draft.md", "universe/items/the-brass-key.md",
            "universe/locations/the-station.md", "universe/rules/time-travel.md",
            "script/script.md", "script/margin/notes.md", "script/title-page.md",
        ]
        return LinkGraph(files: try paths.map { path in
            IndexedFile.index(path: path, text: try String(contentsOf: root.appending(path: path), encoding: .utf8))
        })
    }

    @Test func resolvesByNameThenAliasThenFileName() throws {
        let graph = try sampleGraph()
        #expect(graph.resolve("The Brass Key") == .init(path: "universe/items/the-brass-key.md", via: .name))
        #expect(graph.resolve("the brass key") == .init(path: "universe/items/the-brass-key.md", via: .name))
        #expect(graph.resolve("The Courier") == .init(path: "universe/characters/mara-voss.md", via: .alias))
        #expect(graph.resolve("time-travel") == .init(path: "universe/rules/time-travel.md", via: .fileName))
        #expect(graph.resolve("Time Travel")?.via == .alias)
        #expect(graph.resolve("The Archivist") == nil)
        // The rough draft's H1 is not a note name.
        #expect(graph.notes.map(\.name) == ["Loop Rules", "Mara Voss", "The Brass Key", "The Station"])
    }

    @Test func ignoresAccentsAndSpacing() {
        let graph = LinkGraph(files: [IndexedFile.index(path: "universe/characters/elodie.md", text: "---\nname: Élodie  Marchand\n---\n")])
        #expect(graph.resolve("elodie marchand")?.path == "universe/characters/elodie.md")
    }

    @Test func backlinksComeFromNotesScenesAndMargin() throws {
        let graph = try sampleGraph()
        let sources = graph.backlinks(to: "universe/items/the-brass-key.md")
        #expect(Set(sources.map(\.kind)) == [.note, .scene, .margin, .draft])
        let scene = try #require(sources.first { $0.kind == .scene })
        #expect(scene.sceneID == "s014")
        #expect(scene.sceneHeading == "INT. KITCHEN - NIGHT")
        #expect(scene.snippet.hasPrefix("Rain hammers"))
        #expect(graph.backlinks(to: "universe/characters/mara-voss.md").map(\.path).sorted() == [
            "universe/draft.md", "universe/items/the-brass-key.md", "universe/items/the-brass-key.md",
            "universe/locations/the-station.md",
        ])
    }

    @Test func listsUnresolvedLinks() throws {
        let graph = try sampleGraph()
        #expect(graph.unresolved.map(\.link.target) == ["The Archivist"])
        #expect(graph.unresolved(in: "universe/rules/time-travel.md").count == 1)
    }

    @Test func completesNamesThenAliases() throws {
        let graph = try sampleGraph()
        #expect(graph.completions(prefix: "The").map(\.text) == ["The Brass Key", "The Station", "The Courier", "the key"])
        #expect(graph.completions(prefix: "brass").map(\.text) == ["The Brass Key"])
        #expect(graph.completions(prefix: "MAR").first?.text == "Mara Voss")
    }

    @Test func characterAppearancesFromCues() throws {
        let text = try String(contentsOf: Fixtures.sampleProject.appending(path: "script/script.md"), encoding: .utf8)
        let book = ScriptBook(texts: [("script/script.md", text)])
        let mara = CharacterAppearances(names: ["Mara Voss", "Mara"], book: book)
        #expect(mara.entries.count == 1)
        #expect(mara.totalSpeeches == 1)
        #expect(CharacterAppearances(names: ["Nobody"], book: book).entries.isEmpty)
        #expect(CharacterAppearances(names: ["Nobody"], book: book, linkedScenes: ["s014"]).entries.count == 1)
    }
}

@Suite("Link index on disk")
@MainActor
struct LinkIndexTests {
    @Test func buildsUpdatesAndRebuildsFromAMissingCache() async throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let index = LinkIndex(store: store)
        #expect(index.graph.backlinks(to: "universe/items/the-brass-key.md").count == 4)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: LinkIndex.cachePath).path))

        // Unsaved edits count.
        let draft = try store.document(at: "universe/draft.md")
        draft.text += "\nAnd [[The Archivist]] watches.\n"
        index.update(path: draft.relativePath, text: draft.text)
        #expect(index.graph.unresolved.count == 2)

        // A note added outside Slate.
        try folder.write("---\nname: The Archivist\n---\n", to: "SampleProject/universe/characters/the-archivist.md")
        store.handleExternalChanges(["universe/characters/the-archivist.md"])
        index.refresh()
        #expect(index.graph.unresolved.isEmpty)

        // The cache is only a speed-up.
        try FileManager.default.removeItem(at: root.appending(path: ".slate/index"))
        let rebuilt = LinkIndex(store: store)
        #expect(rebuilt.graph.notes.count == 5)

        // A stale cache entry (wrong contents, same path) is replaced when the file changes.
        try folder.write("---\nname: Renamed Station\n---\n", to: "SampleProject/universe/locations/the-station.md")
        store.handleExternalChanges(["universe/locations/the-station.md"])
        let third = LinkIndex(store: store)
        #expect(third.graph.resolve("Renamed Station") != nil)
    }
}

@Suite("Rename")
@MainActor
struct RenameTests {
    @Test func plansPlainShownAndAliasCases() throws {
        let graph = LinkGraph(files: [
            IndexedFile.index(path: "universe/items/key.md", text: "---\nname: Key\naliases: [the key]\n---\n"),
            IndexedFile.index(path: "universe/a.md", text: "[[Key]] and [[key|it]] and [[the key]] and [[Key#Origin]]\n```\n[[Key]]\n```\n"),
            IndexedFile.index(path: "script/script.md", text: "# INT. ROOM {#s001}\n\nShe holds [[Key]].\n"),
        ])
        let plan = try #require(RenameRefactor.plan(renaming: "universe/items/key.md", to: "Brass Key", in: graph, existingPaths: ["universe/items/key.md"]))
        #expect(plan.edits.count == 4)
        #expect(plan.fileCount == 2)
        #expect(plan.newPath == "universe/items/brass-key.md")
        let text = "[[Key]] and [[key|it]] and [[the key]] and [[Key#Origin]]\n```\n[[Key]]\n```\n"
        let updated = FileEdit.apply(plan.edits.filter { $0.path == "universe/a.md" }, to: text)
        #expect(updated == "[[Brass Key]] and [[Brass Key|it]] and [[the key]] and [[Brass Key#Origin]]\n```\n[[Key]]\n```\n")
    }

    @Test func editsSkipChangedText() {
        let edit = FileEdit(path: "a", range: NSRange(location: 2, length: 3), original: "Key", replacement: "Lock")
        #expect(FileEdit.apply([edit], to: "[[Key]]") == "[[Lock]]")
        #expect(FileEdit.apply([edit], to: "[[Kex]]") == nil)
    }

    @Test func appliesAcrossOpenAndClosedFilesAndMovesTheNote() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let index = LinkIndex(store: store)
        let open = try store.document(at: "script/margin/notes.md")

        let plan = try #require(RenameRefactor.plan(
            renaming: "universe/items/the-brass-key.md", to: "The Copper Key", in: index.graph,
            existingPaths: Set(store.files.values.flatMap { $0 }.map(\.relativePath))
        ))
        #expect(plan.fileCount == 3) // the draft links by alias
        let newPath = try RenameRefactor.apply(plan, updateLinks: true, store: store)
        #expect(newPath == "universe/items/the-copper-key.md")

        // Open documents change in memory; closed files on disk.
        #expect(open.text.contains("[[The Copper Key]]"))
        #expect(open.isDirty)
        #expect(try folder.read("SampleProject/script/script.md").contains("[[The Copper Key|a brass key]]"))
        #expect(try folder.read("SampleProject/universe/characters/mara-voss.md").contains("[[The Copper Key]]"))
        // Alias links stay.
        #expect(try folder.read("SampleProject/universe/draft.md").contains("[[the key|a brass key]]"))
        // The note moved, kept its id, and has the new name.
        let moved = try folder.read("SampleProject/universe/items/the-copper-key.md")
        #expect(moved.contains("id: i-2b91\nname: The Copper Key\n"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "universe/items/the-brass-key.md").path))

        index.update(path: open.relativePath, text: open.text)
        index.refresh()
        #expect(index.graph.backlinks(to: newPath).count == 4)
    }

    @Test func trashMovesToTrashNotDelete() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        try store.trashFile("universe/rules/time-travel.md")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "universe/rules/time-travel.md").path))
        #expect(store.files[.universe]?.contains { $0.relativePath == "universe/rules/time-travel.md" } == false)
    }
}

@Suite("Search and quick open")
struct SearchTests {
    @Test func ignoresCaseAndAccents() {
        let results = ProjectSearch.search("cafe", in: [
            ("universe/a.md", "The Café opens.\nAnother CAFE here."),
            ("script/script.md", "Nothing"),
        ])
        #expect(results.count == 1)
        #expect(results[0].matches.map(\.line) == [0, 1])
        #expect(results[0].matches[0].snippet == "The Café opens.")
        #expect((results[0].matches[0].snippet as NSString).substring(with: results[0].matches[0].snippetRange) == "Café")
    }

    @Test func quotedQueryKeepsSpaces() {
        let texts: [(path: String, text: String)] = [("a.md", "brass key"), ("b.md", "brass  key")]
        #expect(ProjectSearch.search("\"brass key\"", in: texts).map(\.path) == ["a.md"])
        #expect(ProjectSearch.search("  ", in: texts).isEmpty)
    }

    @Test func longLinesAreShortenedAroundTheMatch() {
        let line = String(repeating: "word ", count: 40) + "needle" + String(repeating: " more", count: 40)
        let match = ProjectSearch.search("needle", in: [("a.md", line)])[0].matches[0]
        #expect(match.snippet.hasPrefix("…"))
        #expect(match.snippet.hasSuffix("…"))
        #expect((match.snippet as NSString).substring(with: match.snippetRange) == "needle")
    }

    @Test func searchesDiskWithOpenBuffersWinning() throws {
        let results = ProjectSearch.search("Rain", root: Fixtures.sampleProject,
                                            paths: ["script/script.md", "universe/draft.md", "exports/x.pdf", ".slate/index/links.json"],
                                            overrides: ["universe/draft.md": "Rain again"])
        #expect(results.map(\.path) == ["script/script.md", "universe/draft.md"])
    }

    @Test func quickOpenRanksTitlesAndWordStarts() {
        let items = [
            QuickOpen.Item(kind: .file, title: "notes.md", subtitle: "", path: "script/margin/notes.md"),
            QuickOpen.Item(kind: .note, title: "Mara Voss", subtitle: "Character", path: "universe/characters/mara-voss.md", keywords: ["The Courier"]),
            QuickOpen.Item(kind: .scene, title: "INT. KITCHEN - NIGHT", subtitle: "Scene 1", path: "script/script.md", sceneRow: "x"),
            QuickOpen.Item(kind: .note, title: "Marathon", subtitle: "Event", path: "universe/events/marathon.md"),
        ]
        #expect(QuickOpen.rank(items, query: "mv").first?.title == "Mara Voss")
        #expect(QuickOpen.rank(items, query: "kitch").map(\.title) == ["INT. KITCHEN - NIGHT"])
        #expect(QuickOpen.rank(items, query: "courier").map(\.title) == ["Mara Voss"])
        #expect(QuickOpen.rank(items, query: "mara").map(\.title) == ["Mara Voss", "Marathon"])
        #expect(QuickOpen.rank(items, query: "").count == 4)
        #expect(QuickOpen.rank(items, query: "zzz").isEmpty)
    }
}

@Suite("Markdown styling scanner")
struct MarkdownSyntaxTests {
    func kinds(_ line: String) -> [MarkdownSyntax.SpanKind] {
        MarkdownSyntax.scan(line: line, inFence: false).line.spans.map(\.kind)
    }

    @Test func lineKinds() {
        let lines = MarkdownSyntax.scan("## Want\n> quote\n- item\n- [x] done\n1. one\n---\n```swift\nlet a = [[x]]\n```\n\nplain")
        #expect(lines.map(\.kind) == [
            .heading(2), .quote, .listItem, .task(done: true), .listItem, .rule, .fence, .code, .fence, .blank, .text,
        ])
        #expect(lines[7].spans.isEmpty)
    }

    @Test func inlineSpans() {
        let spans = MarkdownSyntax.scan(line: "A **bold** and *it* and `[[no]]` and [[Mara|her]].", inFence: false).line.spans
        let ns = "A **bold** and *it* and `[[no]]` and [[Mara|her]]." as NSString
        func text(_ kind: MarkdownSyntax.SpanKind) -> [String] {
            spans.filter { $0.kind == kind }.map { ns.substring(with: $0.range) }
        }
        #expect(text(.bold) == ["**bold**"])
        #expect(text(.italic) == ["*it*"])
        #expect(text(.code) == ["`[[no]]`"])
        #expect(text(.link(target: "Mara")) == ["[[Mara|her]]"])
        #expect(text(.marker).contains("Mara|"))
    }

    @Test func snakeCaseIsNotItalic() {
        #expect(!kinds("snake_case_name").contains(.italic))
        #expect(kinds("_yes_").contains(.italic))
        #expect(!kinds("2 * 3 * 4").contains(.italic))
    }
}
