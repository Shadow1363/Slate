import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Templates and infobox UI")
struct TemplateUITests {
    @Test func yourNoteBuildsItsInfobox() throws {
        let h = try SessionHarness()
        let path = "universe/characters/thomas-wiley-cade.md"
        let note = try #require(h.session.links.graph.note(at: path))
        let template = h.session.template(for: note.type)
        #expect(template?.type == "character")
        let content = InfoboxContent.make(note: note, template: template, store: h.store)
        #expect(content.name == "Thomas Wiley Cade")
        #expect(content.subtitle == "The Broken")
        #expect(content.typeLabel == "Character")
        // The note's own layout: a Powers header above two columns.
        let visible = content.visibleRows
        let header = try #require(visible.firstIndex(of: .header("Powers")))
        #expect(visible[header + 1] == .columns(["powers1", "powers2"]))
        #expect(visible.contains(.field("status")))
        // Empty template fields aren't shown, but are there to edit.
        #expect(!visible.contains(.field("age")))
        #expect(content.keys.contains("age"))
        #expect(content.type(for: "powers1") == .links)
        #expect(content.type(for: "alive") == .bool)
        // Links in it resolve and show as backlinks on Powers.
        #expect(h.session.links.graph.backlinks(to: "universe/rules/powers.md").filter { $0.path == path }.count == 3)
    }

    @Test func savingATemplateFeedsNewNotes() throws {
        let h = try SessionHarness()
        let session = h.session
        let (type, folder) = TemplateLibrary.newType(label: "Creature", existing: Set(session.templates.map(\.type)))
        var placements = [InfoboxLayout.Placement(key: "name"), .init(key: "habitat"), .init(key: "size", besidePrevious: true),
                          .init(key: "danger", section: "Threat")]
        var template = NoteTemplate(type: type, label: "Creature", folder: folder, icon: "pawprint.fill",
                                    fields: [.init(key: "name", type: .text), .init(key: "habitat", type: .text),
                                             .init(key: "size", type: .choice, options: ["small", "huge"]), .init(key: "danger", type: .bool)],
                                    body: "## Behaviour\n", origin: .project)
        template.layout = InfoboxLayout.layout(from: placements)
        #expect(session.saveTemplate(template, to: .project, replacing: nil))
        let saved = try #require(session.templates.first { $0.type == "creature" })
        #expect(saved.origin == .project)
        #expect(saved.layout == [.columns(["habitat", "size"]), .header(text: "Threat", above: "danger")])
        let text = try h.read("templates/creature.md")
        #expect(text.contains("  size: {type: choice, options: [small, huge]}\n"))

        let path = try session.createNote(template: saved, name: "Glass Eel")
        #expect(path == "universe/creatures/glass-eel.md")
        let note = try h.read(path)
        #expect(note.contains("type: creature\n"))
        #expect(note.contains("\nhabitat:\nsize:\ndanger:\n---\n## Behaviour\n"))

        // Edit and move it to the project's other template, then remove it.
        placements[3].section = nil
        var edited = saved
        edited.layout = InfoboxLayout.layout(from: placements)
        #expect(session.saveTemplate(edited, to: .project, replacing: saved))
        #expect(session.templates.first { $0.type == "creature" }?.layout == [.columns(["habitat", "size"])])
        session.removeTemplate(try #require(session.templates.first { $0.type == "creature" }))
        #expect(!session.templates.contains { $0.type == "creature" })
    }

    @Test func builtInsAreCopiedNotChanged() throws {
        let h = try SessionHarness()
        let session = h.session
        var location = try #require(session.templates.first { $0.type == "location" })
        #expect(location.origin == .builtIn)
        location.fields.append(.init(key: "climate", type: .choice, options: ["wet", "dry"]))
        #expect(session.saveTemplate(location, to: .project, replacing: nil))
        let copy = try #require(session.templates.first { $0.type == "location" })
        #expect(copy.origin == .project)
        #expect(copy.field("climate")?.options == ["wet", "dry"])
        session.removeTemplate(copy)
        #expect(session.templates.first { $0.type == "location" }?.origin == .builtIn)
    }

    @Test func infoboxEditsChangeOneLine() throws {
        let h = try SessionHarness()
        let document = try h.store.document(at: "universe/characters/thomas-wiley-cade.md")
        let before = document.text.components(separatedBy: "\n")
        document.text = Frontmatter.setting("height", to: .string("5'8\""), in: document.text)
        let after = document.text.components(separatedBy: "\n")
        #expect(before.count == after.count)
        #expect(zip(before, after).filter { $0 != $1 }.count == 1)
        #expect(after.contains("height: 5'8\""))
        // The layout block is untouched.
        #expect(document.text.contains("- type: columns\n  keys: [powers1,powers2]\n"))
    }
}
