import Foundation
import Testing
@testable import SlateCore

@Suite("Word book")
struct WordBookTests {
    static let book = """
    # Dictionary

    Intro paragraph, which is not a word.

    ## A

    - **Aetherium** *noun* (aetheric) — A made-up element. See [[Aetherium]].

    ## C

    - **Chronoshift** (chronoshifts, chronoshifted) — A jump between loops.
      It keeps memory.
    - Calloway

    ## R

    - Riley
    - **Rhodium-9** — [[Rhodium-9]]
    - Rook: the courier's call sign
    """

    @Test func parsesEveryEntryShape() throws {
        let entries = WordBook.parse(Self.book)
        #expect(entries.map(\.word) == ["Aetherium", "Chronoshift", "Calloway", "Riley", "Rhodium-9", "Rook"])
        let aetherium = entries[0]
        #expect(aetherium.part == "noun")
        #expect(aetherium.forms == ["aetheric"])
        #expect(aetherium.explanation == "A made-up element. See [[Aetherium]].")
        #expect(aetherium.links.map(\.target) == ["Aetherium"])
        let chrono = entries[1]
        #expect(chrono.explanation == "A jump between loops.\nIt keeps memory.")
        #expect(chrono.lines == 10..<12)
        #expect(chrono.allForms == ["Chronoshift", "chronoshifts", "chronoshifted"])
        #expect(entries[2].isSpellingOnly)
        #expect(entries[3].isSpellingOnly)
        #expect(entries[4].linkedNoteOnly == "Rhodium-9")
        #expect(aetherium.linkedNoteOnly == nil)
        #expect(entries[5].explanation == "the courier's call sign")
    }

    @Test func pastedWordListsAndCommentsWork() {
        let entries = WordBook.parse("chronoshift\n\n# comment\nVoss\nThis is a sentence of prose.\n<!-- - Hidden -->\n")
        #expect(entries.map(\.word) == ["chronoshift", "Voss"])
    }

    @Test func writesEntries() {
        #expect(WordEntry(word: "Riley").markdownLines == ["- Riley"])
        #expect(WordEntry(word: "Aetherium", part: "noun", forms: ["aetheric"], explanation: "An element.\nRare.").markdownLines
                == ["- **Aetherium** *noun* (aetheric) — An element.", "  Rare."])
        // Round trip through the parser.
        let entry = WordEntry(word: "Ünder", part: "verb", forms: ["ünders"], explanation: "To go under. See [[Below]].")
        let parsed = WordBook.parse(entry.markdownLines.joined(separator: "\n"))
        #expect(parsed.map(\.word) == ["Ünder"])
        #expect(parsed.first?.explanation == entry.explanation)
        #expect(parsed.first?.part == "verb")
    }

    @Test func addsUnderTheRightLetterInOrder() {
        var text = WordBook.adding(WordEntry(word: "Bristle"), to: Self.book)
        #expect(text.contains("- **Aetherium** *noun* (aetheric) — A made-up element. See [[Aetherium]].\n\n## B\n\n- Bristle\n\n## C\n"))
        text = WordBook.adding(WordEntry(word: "cartouche", explanation: "A frame."), to: text)
        // After Calloway? No: "cartouche" sorts after "Calloway" and before "Chronoshift".
        let words = WordBook.parse(text).map(\.word)
        #expect(words == ["Aetherium", "Bristle", "cartouche", "Chronoshift", "Calloway", "Riley", "Rhodium-9", "Rook"])
        text = WordBook.adding(WordEntry(word: "Zed"), to: text)
        #expect(text.hasSuffix("- Rook: the courier's call sign\n\n## Z\n\n- Zed\n"))
        text = WordBook.adding(WordEntry(word: "9-Ball"), to: text)
        #expect(text.hasSuffix("## Z\n\n- Zed\n\n## #\n\n- 9-Ball\n"))
    }

    @Test func startsAnEmptyBook() {
        #expect(WordBook.adding(WordEntry(word: "Riley"), to: "") == "# Dictionary\n\n## R\n\n- Riley\n")
        #expect(WordBook.adding(WordEntry(word: "Riley"), to: WordBook.starter) == "# Dictionary\n\n## R\n\n- Riley\n")
        let empty = "# Dictionary\n\n## R\n\n## S\n"
        #expect(WordBook.adding(WordEntry(word: "Riley"), to: empty) == "# Dictionary\n\n## R\n\n- Riley\n\n## S\n")
    }

    @Test func replacesAndRemovesOnlyTheEntry() throws {
        let entries = WordBook.parse(Self.book)
        let chrono = entries[1]
        var updated = chrono
        updated.explanation = "A loop jump."
        let replaced = try #require(WordBook.replacing(chrono, with: updated, in: Self.book))
        #expect(replaced == Self.book.replacingOccurrences(of: "— A jump between loops.\n  It keeps memory.", with: "— A loop jump."))

        // Changing the first letter refiles it.
        var moved = entries[2]
        moved.word = "Ardent"
        let refiled = try #require(WordBook.replacing(entries[2], with: moved, in: Self.book))
        #expect(WordBook.parse(refiled).map(\.word).prefix(2) == ["Aetherium", "Ardent"])

        let removed = try #require(WordBook.removing(entries[3], in: Self.book))
        #expect(!removed.contains("- Riley\n"))
        #expect(removed.components(separatedBy: "\n").count == Self.book.components(separatedBy: "\n").count - 1)

        // Lines that changed since they were read are refused.
        let edited = Self.book.replacingOccurrences(of: "- Riley", with: "- Rileigh")
        #expect(WordBook.removing(entries[3], in: edited) == nil)
    }

    @Test func unchangedBookRoundTrips() {
        // Parsing never rewrites; adding then removing gives the original back.
        let added = WordBook.adding(WordEntry(word: "Rafter"), to: Self.book + "\n")
        let entry = WordBook.parse(added).first { $0.word == "Rafter" }!
        #expect(WordBook.removing(entry, in: added) == Self.book + "\n")
    }

    @Test func searchRanksWordsFirst() {
        let entries = WordBook.parse(Self.book)
        #expect(WordBook.search("chrono", in: entries).map(\.word) == ["Chronoshift"])
        #expect(WordBook.search("r", in: entries).map(\.word).prefix(3) == ["Rhodium-9", "Riley", "Rook"])
        #expect(WordBook.search("loops", in: entries).map(\.word) == ["Chronoshift"])
        #expect(WordBook.search("AETHERIC", in: entries).map(\.word) == ["Aetherium"])
        #expect(WordBook.search("", in: entries).first?.word == "Aetherium")
        #expect(WordBook.entry(for: "chronoshifted", in: entries)?.word == "Chronoshift")
        #expect(WordBook.letter(for: "Éclair") == "E")
        #expect(WordBook.letter(for: "9-Ball") == "#")
    }
}

@Suite("Spelling and terms")
struct SpellingTermTests {
    @Test func mergesEveryWordSource() {
        let project = WordBook.parse("- Riley\n- **Rhodium-9** (rhodiums) — x\n")
        let global = WordBook.parse("- Calloway\n")
        let words = SpellService.ignoredWords(books: [project, global], characters: ["Mara Voss"])
        for word in ["Riley", "RILEY", "Rhodium-9", "Rhodium", "rhodiums", "Calloway", "Mara", "VOSS", "CONT'D"] {
            #expect(words.contains(word), "missing \(word)")
        }
    }

    @Test func matchesWholeWordsLongestFormFirst() {
        let entries = WordBook.parse("""
        - **Chronoshift** (chronoshifted) — A jump.
        - **Zoë** — A name.
        - **Brass Key** — See [[The Brass Key]].
        - Riley
        """)
        let matcher = TermMatcher(entries: entries)
        let text = "She chronoshifted. Chronoshifts aren't words; CHRONOSHIFT is. Zoe and Zoë. Riley holds the brass key [[Chronoshift]]."
        let ns = text as NSString
        let hits = matcher.matches(in: text, excluding: TermMatcher.protectedRanges(in: text))
        #expect(hits.map { ns.substring(with: $0.range) } == ["chronoshifted", "CHRONOSHIFT", "Zoe", "Zoë", "brass key"])
        #expect(hits.map(\.word) == ["Chronoshift", "Chronoshift", "Zoë", "Zoë", "Brass Key"])
        #expect(TermMatcher(entries: WordBook.parse("- Riley\n")).isEmpty)
    }

    @Test func findsUsesAcrossFiles() {
        let entry = WordBook.parse("- **Chronoshift** (chronoshifted) — A jump.\n")[0]
        let texts: [(path: String, text: String)] = [
            ("script/script.md", "INT. LAB - DAY {#s001}\n\nShe chronoshifted.\n"),
            ("universe/rules/time-travel.md", "A chronoshift costs a memory. [[Chronoshift]]\n"),
            (WordBook.path, "- **Chronoshift** — A jump.\n"),
            (".slate/index/links.json", "chronoshift"),
        ]
        let uses = TermUsage.uses(of: entry, in: texts)
        #expect(uses.map(\.path) == ["script/script.md", "universe/rules/time-travel.md"])
        #expect(uses[0].matches[0].line == 2)
        #expect(uses[1].matches.count == 1)
    }

    @Test func dictionaryLinksAreBacklinks() {
        let file = IndexedFile.index(path: WordBook.path, text: "- **Brass Key** — See [[The Brass Key]].\n")
        #expect(file.links.map(\.link.target) == ["The Brass Key"])
        #expect(file.links.first?.kind == .dictionary)
        #expect(file.note == nil)
        #expect(IndexedFile.index(path: "dictionary/other.md", text: "[[X]]").links.isEmpty)
    }
}

@Suite("Dictionary migration")
struct DictionaryMigrationTests {
    @Test func wordListAndTermFilesBecomeTheBook() throws {
        let folder = try TempFolder()
        let old = ProjectManifest(name: "Old", schemaVersion: 2)
        let original = try old.encoded()
        try original.write(to: folder.file("project.json"))
        try folder.write("# my words\nchronoshift\nRiley\n", to: "dictionary/words.txt")
        try folder.write("""
        ---
        type: term
        word: Chronoshift
        part: noun
        forms: [chronoshifts]
        definition: A jump between loops
        ---

        Long notes.
        """, to: "dictionary/terms/chronoshift.md")

        _ = try ProjectMigrator.migrateIfNeeded(old, originalData: original, projectRoot: folder.url)

        let book = try folder.read(WordBook.path)
        #expect(book == """
        # Dictionary

        ## C

        - **Chronoshift** *noun* (chronoshifts) — A jump between loops. See [[Chronoshift]].

        ## R

        - Riley

        """)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: folder.file("dictionary/words.txt").path))
        #expect(!fm.fileExists(atPath: folder.file("dictionary/terms").path))
        #expect(try folder.read("universe/notes/chronoshift.md").hasSuffix("Long notes."))
        let backups = try fm.contentsOfDirectory(atPath: folder.file(".slate/backups").path)
        let dictionaryBackup = try #require(backups.first { $0.hasPrefix("dictionary-v2-") })
        #expect(try folder.read(".slate/backups/\(dictionaryBackup)/words.txt") == "# my words\nchronoshift\nRiley\n")
        #expect(fm.fileExists(atPath: folder.file(".slate/backups/\(dictionaryBackup)/terms/chronoshift.md").path))
    }
}
