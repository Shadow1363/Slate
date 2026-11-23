import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@Suite("Voice notes")
@MainActor
struct VoiceUITests {
    @Test func transcriptBecomesATaggedFreeformNote() throws {
        let h = try SessionHarness()
        let path = try h.session.createVoiceNote(transcript: "Mara hides the key in the boat. Then the storm comes.",
                                                 source: URL(fileURLWithPath: "/tmp/Memo 12.m4a"))
        #expect(path == "universe/notes/mara-hides-the-key-in-the-boat.md")
        let text = try h.read(path)
        #expect(text.hasPrefix("---\ntype: note\n"))
        #expect(text.contains("name: Mara hides the key in the boat"))
        #expect(text.contains("recording: Memo 12.m4a"))
        #expect(text.contains("voice-note"))
        #expect(text.hasSuffix("\nMara hides the key in the boat. Then the storm comes.\n"))
        #expect(h.session.links.graph.notes.contains { $0.path == path })
        #expect(h.session.tagIndex.tags.contains { $0.tag == "voice-note" })
    }
}
