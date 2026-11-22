import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Dictionary")
struct DictionaryUITests {
    @Test func readsTheSampleBook() throws {
        let h = try SessionHarness()
        let dictionary = h.session.dictionary
        #expect(dictionary.entries.map(\.word) == ["Brass Key", "Chronoshift", "Mara", "Riley"])
        #expect(dictionary.entry(for: "chronoshifted")?.word == "Chronoshift")
        #expect(dictionary.globalEntries.isEmpty)
        #expect(!dictionary.matcher.isEmpty)
    }

    @Test func markdownEditorIgnoresDictionaryWords() throws {
        let m = try MarkdownHarness(path: ProjectLayout.draft, hidesFrontmatter: false)
        let ignored = NSSpellChecker.shared.ignoredWords(inSpellDocumentWithTag: m.textView.spellCheckerDocumentTag) ?? []
        for word in ["Riley", "Chronoshift", "chronoshifted", "Mara", "Voss"] {
            #expect(ignored.contains(word), "missing \(word)")
        }
        #expect(m.textView.isGrammarCheckingEnabled == SpellingPreferences.current.grammarInNotes)
    }

    @Test func underlinesDefinedWords() throws {
        let m = try MarkdownHarness(path: ProjectLayout.draft, hidesFrontmatter: false)
        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length, length: 0))
        m.type("\nShe chronoshifted with the brass key. Riley [[Chronoshift]].")
        m.controller.terms.refresh()
        let ns = m.textView.string as NSString
        let hits = m.controller.terms.hits.map { ns.substring(with: $0.range) }
        // Spelling-only words aren't marked; words inside links aren't either.
        #expect(hits.suffix(2) == ["chronoshifted", "brass key"])
        let at = ns.range(of: "chronoshifted").location + 3
        #expect(m.controller.terms.hit(at: at)?.word == "Chronoshift")
    }

    @Test func learningWritesTheRightBook() throws {
        let h = try SessionHarness()
        let dictionary = h.session.dictionary
        dictionary.learn("Zorblax", global: false)
        dictionary.learn("riley", global: false) // already there
        let book = try #require(h.store.documents[WordBook.path]).text
        #expect(book.hasSuffix("## R\n\n- Riley\n\n## Z\n\n- Zorblax\n"))
        #expect(book.components(separatedBy: "Riley").count == 2)
        #expect(dictionary.entry(for: "Zorblax") != nil)

        dictionary.learn("Quillion", global: true)
        let global = try String(contentsOf: dictionary.globalURL, encoding: .utf8)
        #expect(global == "# Dictionary\n\n## Q\n\n- Quillion\n")
        #expect(dictionary.globalEntries.map(\.word) == ["Quillion"])
        #expect(!book.contains("Quillion"))
        #expect(dictionary.ignoredWords(characters: []).contains("Quillion"))
    }

    @Test func editsAndStaleEntries() throws {
        let h = try SessionHarness()
        let dictionary = h.session.dictionary
        let riley = try #require(dictionary.entry(for: "Riley"))
        var updated = riley
        updated.explanation = "Mara's daughter. See [[Mara Voss]]."
        dictionary.update(riley, to: updated)
        #expect(dictionary.entry(for: "Riley")?.links.map(\.target) == ["Mara Voss"])
        // The old entry's lines no longer say "- Riley": refused, with a message.
        dictionary.delete(riley)
        #expect(dictionary.error != nil)
        #expect(dictionary.entry(for: "Riley") != nil)
    }

    @Test func menuItemsAndFollowing() throws {
        let h = try SessionHarness()
        let session = h.session
        #expect(session.dictionaryMenuItems(word: "Zorblax", misspelled: true).map(\.title)
                == ["Add to Project Dictionary", "Add to Every Project", "Define “Zorblax” in Dictionary…"])
        #expect(session.dictionaryMenuItems(word: "chronoshifted", misspelled: false).map(\.title) == ["Show “Chronoshift” in Dictionary"])

        // A link-only entry opens its note; one with a meaning opens its page.
        #expect(session.followWord("brass key", inScript: false))
        #expect(session.universeSelection == "universe/items/the-brass-key.md")
        #expect(session.followWord("chronoshifted", inScript: false))
        #expect(session.area == .dictionary)
        #expect(session.dictionarySelection?.key == "chronoshift")
        #expect(!session.followWord("Zorblax", inScript: false))

        #expect(session.wordPreview("chronoshift") != nil)
        #expect(session.wordPreview("Brass Key") != nil)
        #expect(session.wordPreview("Zorblax") == nil)
    }

    @Test func outsideEditsReload() throws {
        let h = try SessionHarness()
        let dictionary = h.session.dictionary
        let document = try #require(h.store.documents[WordBook.path])
        document.text += "\n## Z\n\n- **Zeitgate** — A door in time.\n"
        dictionary.refresh()
        #expect(dictionary.entry(for: "Zeitgate")?.explanation == "A door in time.")
        let before = dictionary.version
        dictionary.refresh()
        #expect(dictionary.version == before)
    }

    @Test func matchingStaysFastWithABigBook() throws {
        let entries = (0..<200).map { WordEntry(word: "Glorp\($0)x", forms: ["glorps\($0)"], explanation: "A word.") }
        let matcher = TermMatcher(entries: entries + [WordEntry(word: "Chronoshift", explanation: "A jump.")])
        let paragraph = "Rain hammers the window. Mara stares at a brass key and chronoshifts again, turning it over.\n\n"
        let text = String(repeating: paragraph, count: 600) // about ten pages and more
        let clock = ContinuousClock()
        var hits: [TermMatcher.Hit] = []
        let elapsed = clock.measure { hits = matcher.matches(in: text) }
        print("Matching 200 words over \(text.count) characters: \(elapsed)")
        #expect(hits.isEmpty) // "chronoshifts" isn't a listed form
        #if DEBUG
        #expect(elapsed < .milliseconds(150))
        #else
        #expect(elapsed < .milliseconds(60))
        #endif
    }
}
