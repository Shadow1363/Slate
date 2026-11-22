import Foundation
import Testing
@testable import SlateCore

@Suite("Templates and infobox")
struct TemplateTests {
    @Test func readsEveryFieldType() throws {
        let template = try NoteTemplate(text: """
        ---
        type: hero
        label: Hero
        icon: bolt
        nameField: title
        fields:
          role: {type: choice, label: Part, options: [lead, ally]}
          backstory: long text
          alive: checkbox
          powers: links
          home: link
          born: date
          odd: whatever
        ---
        ## Origin
        """, fileName: "hero.md", origin: .project)
        #expect(template.fields.map(\.key) == ["title", "role", "backstory", "alive", "powers", "home", "born", "odd"])
        #expect(template.fields.map(\.type) == [.text, .choice, .longText, .bool, .links, .link, .date, .text])
        #expect(template.field("role")?.label == "Part")
        #expect(template.field("role")?.options == ["lead", "ally"])
        #expect(template.icon == "bolt")
        #expect(template.nameField == "title")
    }

    @Test func writesAndReadsBack() throws {
        let template = NoteTemplate(
            type: "hero", label: "Hero", folder: "heroes", icon: "bolt", nameField: "title",
            fields: [
                .init(key: "title", type: .text),
                .init(key: "role", type: .choice, label: "Part", options: ["lead", "ally: friend"]),
                .init(key: "first appearance", type: .link),
                .init(key: "alive", type: .bool),
                .init(key: "notes", type: .longText),
            ],
            layout: [.header(text: "Story", above: "first appearance"), .columns(["role", "alive"])],
            body: "## Origin\n", origin: .project
        )
        let text = template.text
        #expect(text.contains("  role: {type: choice, label: Part, options: [lead, \"ally: friend\"]}\n"))
        #expect(text.contains("  first appearance: link\n"))
        #expect(text.contains("nameField: title\n"))
        let back = try NoteTemplate(text: text, fileName: "hero.md", origin: .project)
        #expect(back == template)
    }

    @Test func newNotesUseTheNameField() throws {
        let template = NoteTemplate(type: "hero", label: "Hero", folder: "heroes", nameField: "title",
                                    fields: [.init(key: "powers", type: .links), .init(key: "alive", type: .bool)], origin: .project)
        let note = template.newNote(name: "Tom", id: "h-0001")
        #expect(note.hasPrefix("---\ntype: hero\nid: h-0001\ntitle: Tom\npowers: []\nalive:\n---\n"))
        #expect(Note(path: "universe/heroes/tom.md", text: note).name == "Tom")
    }

    @Test func infoboxNameResolvesTheTemplate() throws {
        let note = try sampleNote("universe/characters/thomas-wiley-cade.md")
        #expect(note.type == "Character")
        #expect(note.name == "Thomas Wiley Cade")
        #expect(note.subtitle == "The Broken")
        let templates = NoteTemplates.builtIn
        #expect(NoteTemplates.matching(note.type, in: templates)?.type == "character")
        #expect(NoteTemplates.matching("FREEFORM NOTE", in: templates)?.type == "note")
        #expect(NoteTemplates.matching("dragon", in: templates) == nil)
    }

    @Test func yourInfoboxLaysOutAsWritten() throws {
        let note = try sampleNote("universe/characters/thomas-wiley-cade.md")
        let layout = InfoboxLayout.parse(note.value("layout"))
        #expect(layout == [.header(text: "Powers", above: "powers1"), .columns(["powers1", "powers2"])])
        let rows = InfoboxLayout.rows(templateKeys: [], noteKeys: note.fields.map(\.key), layout: layout,
                                      excluding: InfoboxLayout.structuralKeys)
        #expect(rows == [
            .field("race"), .field("gender"), .field("height"), .field("alignment"), .field("aliases"),
            .field("status"), .field("tags"), .header("Powers"), .columns(["powers1", "powers2"]),
        ])
        let links = (note.value("powers1")?.items ?? []) + (note.value("powers2")?.items ?? [])
        let parsed = links.flatMap { WikiLink.find(in: $0) }
        #expect(parsed.map(\.target) == ["Powers", "Powers", "Powers"])
        #expect(parsed.map(\.displayText) == ["Pyrokenisis", "“Teleportation“", "Regeneration"])
        #expect(parsed.first?.heading == "Pyrokenisis")
        #expect(Spoiler.pieces(note.value("status")?.text ?? "") == [.init(text: "Deceased", isSpoiler: true)])
    }

    @Test func noteLayoutWinsAndNothingIsHidden() {
        let rows = InfoboxLayout.rows(
            templateKeys: ["age", "role", "home"], noteKeys: ["home", "extra", "age"],
            layout: [.header(text: "Facts", above: nil), .columns(["age", "role"]), .columns(["missing", "home"]), .field("ghost")],
            excluding: []
        )
        #expect(rows == [.header("Facts"), .columns(["age", "role"]), .field("home"), .field("extra"), .field("ghost")])
        #expect(InfoboxLayout.imageKey(layout: [], fields: [.init(key: "face", type: .image)], noteKeys: []) == "face")
        #expect(InfoboxLayout.imageKey(layout: [], fields: [], noteKeys: ["Portrait"]) == "Portrait")
    }

    @Test func placementsRoundTrip() {
        let keys = ["name", "age", "role", "home", "powers1", "powers2"]
        let layout: [InfoboxLayout.Item] = [.columns(["age", "role"]), .header(text: "Powers", above: "powers1"), .columns(["powers1", "powers2"])]
        let placements = InfoboxLayout.placements(for: keys, layout: layout)
        #expect(placements.map(\.besidePrevious) == [false, false, true, false, false, true])
        #expect(placements[4].section == "Powers")
        let back = InfoboxLayout.layout(from: placements)
        #expect(back == [.columns(["age", "role"]), .header(text: "Powers", above: "powers1"), .columns(["powers1", "powers2"])])
    }

    @Test func spoilers() {
        #expect(Spoiler.pieces("Alive, then ||dead|| and ||back||.") == [
            .init(text: "Alive, then ", isSpoiler: false), .init(text: "dead", isSpoiler: true),
            .init(text: " and ", isSpoiler: false), .init(text: "back", isSpoiler: true), .init(text: ".", isSpoiler: false),
        ])
        #expect(!Spoiler.contains("a || b"))
        #expect(Spoiler.ranges(in: "||x||").first == NSRange(location: 0, length: 5))
    }

    @Test func otherLineEndingsAreKept() throws {
        let cr = "---\rtitle: Tom\rstatus: \"||Deceased||\"\r---\rBody\r"
        let note = Note(path: "universe/characters/tom.md", text: cr)
        #expect(note.name == "Tom")
        #expect(note.value("status")?.text == "||Deceased||")
        #expect(Frontmatter.setting("race", to: .string("White"), in: cr) == "---\rtitle: Tom\rstatus: \"||Deceased||\"\rrace: White\r---\rBody\r")
        let crlf = "---\r\nname: Tom\r\nage: 3\r\n---\r\nBody\r\n"
        #expect(Frontmatter.setting("age", to: .int(4), in: crlf) == "---\r\nname: Tom\r\nage: 4\r\n---\r\nBody\r\n")
        #expect(Frontmatter.removing("age", in: crlf) == "---\r\nname: Tom\r\n---\r\nBody\r\n")
    }

    @Test func longTextAndBoolFields() throws {
        let text = "---\nname: Tom\nalive: true\n---\n"
        let updated = Frontmatter.setting("backstory", to: .string("Line one.\nLine two."), in: text)
        #expect(updated == "---\nname: Tom\nalive: true\nbackstory: |-\n  Line one.\n  Line two.\n---\n")
        #expect(try Frontmatter.fields(in: updated).first { $0.key == "backstory" }?.value == .string("Line one.\nLine two."))
        #expect(try Frontmatter.fields(in: updated).first { $0.key == "alive" }?.value == .bool(true))
        // Replacing a block replaces all its lines.
        let again = Frontmatter.setting("backstory", to: .string("Short."), in: updated)
        #expect(again == "---\nname: Tom\nalive: true\nbackstory: Short.\n---\n")
        #expect(Frontmatter.setting("first appearance", to: .string("[[Mara]]"), in: text).contains("first appearance: \"[[Mara]]\"\n"))
    }

    @Test func libraryOverridesAndReverts() throws {
        let folder = try TempFolder()
        let project = folder.file("project/templates")
        let global = folder.file("global")
        var character = try #require(NoteTemplates.builtIn.first { $0.type == "character" })
        character.fields.append(.init(key: "alive", type: .bool))
        try TemplateLibrary.save(character, to: .project, replacing: nil, projectTemplates: project, globalTemplates: global)
        var loaded = NoteTemplates.load(projectTemplates: project, globalTemplates: global)
        var saved = try #require(loaded.first { $0.type == "character" })
        #expect(saved.origin == .project)
        #expect(saved.field("alive")?.type == .bool)
        #expect(loaded.map(\.type).prefix(7) == ["character", "location", "rule", "faction", "item", "event", "note"])

        // Moving it to every project removes the project copy.
        saved.label = "Person"
        try TemplateLibrary.save(saved, to: .global, replacing: saved, projectTemplates: project, globalTemplates: global)
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: "character.md").path))
        loaded = NoteTemplates.load(projectTemplates: project, globalTemplates: global)
        let moved = try #require(loaded.first { $0.type == "character" })
        #expect(moved.origin == .global)
        #expect(moved.label == "Person")

        try TemplateLibrary.remove(moved, projectTemplates: project, globalTemplates: global)
        loaded = NoteTemplates.load(projectTemplates: project, globalTemplates: global)
        #expect(loaded.first { $0.type == "character" }?.origin == .builtIn)

        #expect(TemplateLibrary.newType(label: "Space Ship", existing: ["space-ship"]) == ("space-ship-2", "space-ship-2s"))
        #expect(TemplateLibrary.newType(label: "Creatures", existing: []) == ("creatures", "creatures"))
        #expect(TemplateLibrary.hasBuiltIn("character"))
        #expect(!TemplateLibrary.hasBuiltIn("space-ship"))
    }

    private func sampleNote(_ path: String) throws -> Note {
        Note(path: path, text: try String(contentsOf: Fixtures.sampleProject.appending(path: path), encoding: .utf8))
    }
}
