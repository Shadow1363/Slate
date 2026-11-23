import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Templates: nothing fixed")
struct TemplateEditingUITests {
    @Test func renamingATypeRetypesItsNotes() throws {
        let h = try SessionHarness()
        let session = h.session
        let characters = session.notes(ofType: "character")
        #expect(!characters.isEmpty)
        session.retype(notesOf: "character", to: "person")
        #expect(session.notes(ofType: "character").isEmpty)
        #expect(session.notes(ofType: "person").count == characters.count)
        #expect(try h.read(characters[0].path).contains("type: person"))
    }

    @Test func deletingBuiltInsFromAProject() throws {
        let h = try SessionHarness()
        let session = h.session
        let character = try #require(session.templates.first { $0.type == "character" })
        session.deleteTemplate(character, from: .project)
        #expect(!session.templates.contains { $0.type == "character" })
        #expect(session.removedTemplates.contains { $0.type == "character" })
        #expect(try h.read("templates/character.md").contains("removed: true"))
        // Its notes stay. (Restore is tested in SlateCore with temporary folders,
        // so this never touches the real global templates folder.)
        #expect(!session.notes(ofType: "character").isEmpty)
    }
}
