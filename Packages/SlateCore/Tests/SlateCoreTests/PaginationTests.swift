import Foundation
import Testing
@testable import SlateCore

private func paginate(_ text: String, settings: PublishSettings = PublishSettings(), format: ScreenplayFormat? = nil) -> PaginatedScript {
    Paginator(format: format, settings: settings).paginate([ScriptParser.parse(text)])
}

private func texts(_ page: PrintedPage) -> [String] {
    page.rows.map(\.line.text)
}

/// `count` one-line action paragraphs, each a full sentence.
private func filler(_ count: Int) -> String {
    (1...count).map { "Line \($0) of filler." }.joined(separator: "\n\n")
}

@Suite("Pagination")
struct PaginationTests {
    @Test func formatsHaveTheRightLineCounts() {
        #expect(ScreenplayFormat(pageSize: .letter).linesPerPage == 54)
        #expect(ScreenplayFormat(pageSize: .a4).linesPerPage == 58)
    }

    @Test func elementSpacingComesFromTheElements() throws {
        let script = "# INT. KITCHEN - NIGHT {#s1}\n\n\n\nRain.\nMore rain.\n\nMARA\n(quietly)\nHi.\n\nCUT TO:\n\n# EXT. ROOF - DAY {#s2}\n\nWind."
        let page = try #require(paginate(script).pages.first)
        let rows = page.rows.map { ($0.row, $0.line.text) }
        #expect(rows.map(\.0) == [0, 2, 3, 5, 6, 7, 9, 12, 14])
        #expect(rows.map(\.1) == ["INT. KITCHEN - NIGHT", "Rain.", "More rain.", "MARA", "(quietly)", "Hi.", "CUT TO:", "EXT. ROOF - DAY", "Wind."])
        let positions = page.rows.map { ($0.line.x, $0.line.alignment) }
        #expect(positions[0] == (1.5, .left))
        #expect(positions[3] == (3.5, .left))
        #expect(positions[4] == (2.9, .left))
        #expect(positions[5] == (2.5, .left))
        #expect(positions[6] == (7.1, .right))
        #expect(page.rows[0].line.sceneNumber == "1")
        #expect(page.rows[7].line.sceneNumber == "2")
    }

    @Test func boneyardSynopsisTagsAndLinksDoNotPrint() throws {
        let script = "# INT. A {#s001}\n\n= synopsis\n\n/* cut\nthis */\n\nShe holds [[The Brass Key|the key]] and [[Mara]]. /* aside */"
        let page = try #require(paginate(script).pages.first)
        #expect(texts(page) == ["INT. A", "She holds the key and Mara. "])
    }

    @Test func headingNeverEndsAPage() throws {
        // 26 filler paragraphs use rows 0–50; a heading would land on 53.
        let script = filler(26) + "\n\n# INT. LATE {#s1}\n\nShe arrives.\nAnd waits.\nAnd waits."
        let pages = paginate(script).pages
        #expect(pages.count == 2)
        #expect(texts(pages[1]).first == "INT. LATE")
    }

    @Test func dialogueSplitsWithMoreAndContd() throws {
        let speech = (1...8).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let script = filler(24) + "\n\nMARA\n" + speech
        let pages = paginate(script).pages
        #expect(pages.count == 2)
        let bottom = texts(pages[0])
        let top = texts(pages[1])
        #expect(bottom.last == "(MORE)")
        #expect(bottom.contains("MARA"))
        #expect(top.first == "MARA (CONT'D)")
        // Every split part ends at a sentence.
        #expect(bottom.dropLast().last?.hasSuffix(".") == true)
        #expect(top.count >= 3)
    }

    @Test func shortSpeechMovesWhole() throws {
        let script = filler(26) + "\n\nMARA\nOne line.\nTwo lines."
        let pages = paginate(script).pages
        #expect(texts(pages[0]).last == "Line 26 of filler.")
        #expect(texts(pages[1]) == ["MARA", "One line.", "Two lines."])
    }

    @Test func parentheticalIsNeverLeftAtTheBottom() throws {
        let script = filler(25) + "\n\nMARA\nFirst. Second.\n(beat)\nThird. Fourth.\nFifth."
        let pages = paginate(script).pages
        for page in pages {
            #expect(page.rows.last?.line.kind != .parenthetical)
            #expect(page.rows.last?.line.text != "MARA")
        }
    }

    @Test func actionSplitsAtASentence() throws {
        // Six sentences that each fill a line; four fit at the bottom of page 1.
        let long = (1...6).map { "This sentence \($0) is long enough to fill most of a whole line." }.joined(separator: " ")
        let script = filler(25) + "\n\n" + long
        let pages = paginate(script).pages
        #expect(pages.count == 2)
        #expect(texts(pages[0]).suffix(4).allSatisfy { $0.hasPrefix("This sentence") })
        #expect(texts(pages[1]).count == 2)
        #expect(Paginator.endsSentence(texts(pages[0]).last ?? ""))
    }

    @Test func forcedPageBreak() {
        let pages = paginate("One.\n\n===\n\nTwo.").pages
        #expect(pages.map(texts) == [["One."], ["Two."]])
    }

    @Test func automaticContd() throws {
        let script = "# INT. A {#s1}\n\nMARA\nHi.\n\nShe sits.\n\nMARA\nAgain.\n\nMARA (CONT'D)\nThird.\n\n# INT. B {#s2}\n\nMARA\nNew scene."
        let cues = try #require(paginate(script).pages.first).rows.filter { $0.line.kind == .character }.map(\.line.text)
        #expect(cues == ["MARA", "MARA (CONT'D)", "MARA (CONT'D)", "MARA"])
        let off = paginate(script, settings: PublishSettings(autoContd: false)).pages[0].rows.filter { $0.line.kind == .character }.map(\.line.text)
        #expect(off == ["MARA", "MARA", "MARA (CONT'D)", "MARA"])
    }

    @Test func sceneNumbersCanBeTurnedOff() throws {
        let page = try #require(paginate("# INT. A {#s1}\n\nGo.", settings: PublishSettings(sceneNumbers: false)).pages.first)
        #expect(page.rows[0].line.sceneNumber == nil)
    }

    @Test func dualDialogueSitsSideBySide() throws {
        let page = try #require(paginate("\nSTEEL\nScrew retirement.\n\nBRICK ^\nScrew retirement.").pages.first)
        #expect(page.rows.map(\.row) == [0, 0, 1, 1])
        #expect(page.rows.map(\.line.text) == ["STEEL", "BRICK", "Screw retirement.", "Screw retirement."])
        #expect(page.rows[2].line.x == 1.5)
        #expect(page.rows[3].line.x == 4.6)
    }

    @Test func centeredAndLyrics() throws {
        let page = try #require(paginate(">THE END<\n\n~Sing *loud*").pages.first)
        #expect(page.rows[0].line.alignment == .center)
        #expect(page.rows[0].line.text == "THE END")
        #expect(page.rows[1].line.runs.allSatisfy { $0.italic })
    }

    @Test func a4FitsMoreLines() {
        let script = filler(28)
        #expect(paginate(script).pages.count == 2)
        #expect(paginate(script, settings: PublishSettings(pageSize: .a4)).pages.count == 1)
    }

    @Test func eighthsPerScene() {
        let script = "# INT. A {#s1}\n\n" + filler(26) + "\n\n# INT. B {#s2}\n\nShort."
        let result = paginate(script)
        #expect(result.sceneEighths.count == 2)
        #expect(result.sceneEighths[0] == 8) // a full page
        #expect(result.sceneEighths[1] == 1) // at least one eighth
    }

    @Test func pageLookupForPageView() {
        let result = paginate(filler(30))
        #expect(result.pageIndex(for: SourceRef(file: 0, line: 0)) == 0)
        #expect(result.pageIndex(for: SourceRef(file: 0, line: 58)) == 1)
    }
}

@Suite("Emphasis and wrapping")
struct EmphasisTests {
    @Test func markers() {
        #expect(Emphasis.runs(in: "a *b* **c** ***d*** _e_") == [
            PrintedRun("a "), PrintedRun("b", italic: true), PrintedRun(" "), PrintedRun("c", bold: true),
            PrintedRun(" "), PrintedRun("d", bold: true, italic: true), PrintedRun(" "), PrintedRun("e", underline: true),
        ])
        #expect(Emphasis.runs(in: "_**BRICK & STEEL**_") == [PrintedRun("BRICK & STEEL", bold: true, underline: true)])
    }

    @Test func unpairedAndEscapedMarkersPrint() {
        #expect(Emphasis.runs(in: "5 * 3 = 15") == [PrintedRun("5 * 3 = 15")])
        #expect(Emphasis.runs(in: #"a \*not\* b"#) == [PrintedRun("a *not* b")])
        #expect(Emphasis.runs(in: "*a*", enabled: false) == [PrintedRun("*a*")])
    }

    @Test func wrapsAtSpacesAndDropsThem() {
        #expect(LineWrapper.wrap("one two three four", width: 9) == ["one two", "three", "four"])
        #expect(LineWrapper.wrap("A gorgeous day.  The sun.", width: 16) == ["A gorgeous day.", "The sun."])
        #expect(LineWrapper.wrap("abcdefghij", width: 4) == ["abcd", "efgh", "ij"])
        #expect(LineWrapper.wrap("", width: 10) == [""])
    }

    @Test func doubleDashHangs() {
        // 59 characters, then " --": the dashes hang one past the 61 edge.
        let text = "retired police detective, is sitting quietly, contemplating -- something."
        #expect(LineWrapper.wrap(text, width: 61) == ["retired police detective, is sitting quietly, contemplating --", "something."])
    }

    @Test func wrappingKeepsStyles() {
        let lines = LineWrapper.wrap(Emphasis.runs(in: "plain **bold words here**"), width: 11)
        #expect(lines.map { $0.map(\.text).joined() } == ["plain bold", "words here"])
        #expect(lines[1] == [PrintedRun("words here", bold: true)])
    }
}

@Suite("Title page")
struct TitlePageTests {
    @Test func parsesKeysAndContinuations() {
        let page = TitlePage.parse("Title:\n\t_**BRICK & STEEL**_\n\t_**FULL RETIRED**_\nCredit: Written by\nAuthor: Stu Maschwitz\nContact:\n    1588 Mission Dr.\n    Solvang, CA")
        #expect(page.values("title") == ["_**BRICK & STEEL**_", "_**FULL RETIRED**_"])
        #expect(page.values("Author") == ["Stu Maschwitz"])
        #expect(page.values("Contact") == ["1588 Mission Dr.", "Solvang, CA"])
        #expect(TitlePage.parse(page.text) == page)
    }

    @Test func emptyTitlePage() {
        #expect(TitlePage.parse("").isEmpty)
        #expect(TitlePage.parse("Title:\nAuthor:\n").isEmpty)
    }
}

@Suite("Publish settings")
struct PublishSettingsTests {
    @Test func defaultsAndRoundTrip() {
        var manifest = ProjectManifest(name: "Film")
        #expect(PublishSettings(manifest: manifest) == PublishSettings())
        PublishSettings(autoContd: false, sceneNumbers: true, emphasis: false, pageSize: .a4).apply(to: &manifest)
        let reread = PublishSettings(manifest: manifest)
        #expect(!reread.autoContd)
        #expect(!reread.emphasis)
        #expect(reread.pageSize == .a4)
    }
}

@Suite("Exact timings")
struct ExactTimingTests {
    @Test func bookUsesThePaginatorWhenGiven() {
        let text = "# INT. A {#s1}\n\n" + (1...26).map { "Line \($0)." }.joined(separator: "\n\n") + "\n\n# INT. B {#s2}\n\nShort."
        let estimate = ScriptBook(texts: [("s.md", text)])
        let exact = ScriptBook(texts: [("s.md", text)], paginator: Paginator())
        #expect(!estimate.isExact)
        #expect(exact.isExact)
        #expect(exact.scenes.map(\.eighths) == [8, 1])
        #expect(exact.pageCount == 2)
        #expect(exact.scenes[0].duration == 60)
    }
}
