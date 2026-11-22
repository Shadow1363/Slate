import Foundation
import Testing
@testable import SlateCore

private func kinds(_ text: String, hint: ScriptParser.Hint? = nil) -> [ScriptElementKind] {
    ScriptParser.parse(text, hint: hint).lines.map(\.kind)
}

@Suite("ScriptParser")
struct ScriptParserTests {
    @Test func specExample() throws {
        let text = try String(contentsOf: Fixtures.sampleProject.appending(path: "script/script.md"), encoding: .utf8)
        let parsed = ScriptParser.parse(text)
        #expect(parsed.lines.map(\.kind) == [
            .sceneHeading, .blank,
            .action, .blank,
            .character, .parenthetical, .dialogue, .blank,
            .character, .dialogue, .blank,
            .action, .blank,
            .transition,
            .blank, // trailing newline
        ])
        #expect(parsed.scenes.count == 1)
        let scene = parsed.scenes[0]
        #expect(scene.sceneID == "s014")
        #expect(scene.heading == "INT. KITCHEN - NIGHT")
        #expect(scene.range == NSRange(location: 0, length: (text as NSString).length))
        #expect(parsed.characterCues == ["MARA", "OLDER MARA"])
    }

    @Test func headingsFollowFountain() {
        #expect(kinds(".a kitchen") == [.sceneHeading])
        #expect(kinds("INT. KITCHEN - DAY") == [.sceneHeading])
        #expect(kinds("ext. roof - night") == [.sceneHeading])
        #expect(kinds("INT./EXT. CAR - MOVING") == [.sceneHeading])
        #expect(kinds("I/E CAR") == [.sceneHeading])
        #expect(kinds("EST. CITY") == [.sceneHeading])
        #expect(kinds(".FLASHBACK") == [.sceneHeading])
        #expect(kinds("INTERIOR DESIGN IS HARD") == [.action])
        #expect(kinds("...and then") == [.action])
        // Auto-detected headings need a blank line before them; `.` doesn't.
        #expect(kinds("She runs.\nINT. HALL - DAY") == [.action, .action])
        #expect(kinds("She runs.\n.INT. HALL - DAY") == [.action, .sceneHeading])
        // A section above counts as a break.
        #expect(kinds("# ACT ONE\nINT. HALL - DAY") == [.section, .sceneHeading])
    }

    @Test func hashLinesAreSections() throws {
        let parsed = ScriptParser.parse("# Act One\n\n## The heist\n\nINT. VAULT - NIGHT {#s001}\n\nAlarms.")
        #expect(parsed.lines.map(\.kind) == [.section, .blank, .section, .blank, .sceneHeading, .blank, .action])
        #expect(parsed.lines[2].markerLength == 3)
        #expect(parsed.scenes.count == 1)
        #expect(parsed.scenes[0].heading == "INT. VAULT - NIGHT")
    }

    @Test func fountainSceneNumbers() throws {
        let heading = SceneHeading.parse("INT. HOUSE - DAY #1A# {#s003}")
        #expect(heading.heading == "INT. HOUSE - DAY")
        #expect(heading.sceneID == "s003")
        #expect(heading.attributes["number"] == "1A")
        #expect(SceneHeading.parse(".SNOWGLOBE #12#").heading == "SNOWGLOBE")
    }

    @Test func sceneTagsAndDurations() throws {
        let parsed = ScriptParser.parse("INT. KITCHEN - NIGHT {#s014 dur=2:30}\n\nAction.")
        let scene = try #require(parsed.scenes.first)
        #expect(scene.sceneID == "s014")
        #expect(scene.heading == "INT. KITCHEN - NIGHT")
        #expect(scene.durationOverride == 150)
        let line = parsed.lines[0]
        #expect(line.markerLength == 0)
        #expect(line.tagRange == NSRange(location: 20, length: 17))
        #expect(ScriptEstimate.printedText(of: line) == "INT. KITCHEN - NIGHT")
    }

    @Test func headingParts() {
        let parts = SceneHeading.parse("EXT. ROOF - LATER - NIGHT {#s1}").parts
        #expect(parts.prefix == "EXT.")
        #expect(parts.location == "ROOF - LATER")
        #expect(parts.time == "NIGHT")
        #expect(SceneHeading.parse("INT./EXT. CAR").parts.prefix == "INT./EXT.")
        #expect(SceneHeading.parse(".THE VOID").parts.location == "THE VOID")
    }

    @Test func durations() {
        #expect(SceneHeading.parseDuration("90") == 90)
        #expect(SceneHeading.parseDuration("1:02:00") == 3720)
        #expect(SceneHeading.parseDuration("abc") == nil)
        #expect(SceneHeading.parseDuration("-1") == nil)
    }

    @Test func characterNeedsBlankBeforeAndTextAfter() {
        #expect(kinds("\nMARA\nHi.") == [.blank, .character, .dialogue])
        #expect(kinds("\nBOOM.") == [.blank, .action])
        #expect(kinds("\nMARA\n\nHi.") == [.blank, .action, .blank, .action])
        #expect(kinds("Mara walks.\nMARA\nHi.") == [.action, .action, .action])
    }

    @Test func cueExtensionsAndDualDialogue() {
        #expect(kinds("MARA (V.O.)\nHello.") == [.character, .dialogue])
        #expect(kinds("MARA (cont'd)\nHello.") == [.character, .dialogue])
        #expect(kinds("MARA ^\nHello.") == [.character, .dialogue])
        #expect(ScriptParser.characterName(fromCue: "@McCoy (O.S.) ^") == "MCCOY")
    }

    @Test func forcedElements() {
        #expect(kinds("!INT. NOT A HEADING") == [.action])
        #expect(kinds("@McCoy\nHello.") == [.character, .dialogue])
        #expect(kinds(">FADE OUT.") == [.transition])
        #expect(kinds(">THE END<") == [.centered])
        #expect(kinds("~Sing a song") == [.lyric])
        #expect(kinds("= She learns the truth.") == [.synopsis])
        #expect(kinds("===") == [.pageBreak])
        let parsed = ScriptParser.parse("!INT. NOT")
        #expect(parsed.lines[0].markerLength == 1)
    }

    @Test func transitions() {
        #expect(kinds("\nCUT TO:") == [.blank, .transition])
        #expect(kinds("\nSMASH CUT TO:\n\nINT. HALL") == [.blank, .transition, .blank, .sceneHeading])
        #expect(kinds("\nCut to:") == [.blank, .action])
    }

    @Test func dialogueBlock() {
        #expect(kinds("MARA\n(quietly)\nOne.\n(beat)\nTwo.") == [.character, .parenthetical, .dialogue, .parenthetical, .dialogue])
        // Two spaces keep a blank line inside a speech.
        #expect(kinds("MARA\nOne.\n  \nTwo.") == [.character, .dialogue, .dialogue, .dialogue])
    }

    @Test func boneyard() {
        #expect(kinds("/* cut\nthis scene\n*/\nAction.") == [.boneyard, .boneyard, .boneyard, .action])
        #expect(kinds("/* one line */\nAction.") == [.boneyard, .action])
    }

    @Test func hintsDescribeTheLineBeingTyped() {
        // An empty line can become anything.
        #expect(kinds("Action.\n\n", hint: .init(line: 2, kind: .character)) == [.action, .blank, .character])
        // A cue with nothing under it yet is still a cue while the caret is on it.
        #expect(kinds("\nMARA", hint: .init(line: 1, kind: .character)) == [.blank, .character])
        #expect(kinds("\nMARA") == [.blank, .action])
        // The empty dialogue line under a cue keeps the cue a cue.
        #expect(kinds("\nMARA\n", hint: .init(line: 2, kind: .dialogue)) == [.blank, .character, .dialogue])
        // A hint can't force lowercase text into a cue.
        #expect(kinds("\nMara", hint: .init(line: 1, kind: .character)) == [.blank, .action])
    }

    @Test func lineEndingsAndUnicode() {
        let parsed = ScriptParser.parse("INT. CAFÉ — DAY {#s1}\r\n\r\nZoë waves. 🎬\r\n")
        #expect(parsed.lines.map(\.kind) == [.sceneHeading, .blank, .action, .blank])
        #expect(parsed.lines[0].text == "INT. CAFÉ — DAY {#s1}")
        #expect(parsed.lines[2].text == "Zoë waves. 🎬")
        // Ranges are UTF-16 and skip the \r\n.
        let ns = "INT. CAFÉ — DAY {#s1}\r\n\r\nZoë waves. 🎬\r\n" as NSString
        #expect(ns.substring(with: parsed.lines[2].range) == "Zoë waves. 🎬")
        #expect(parsed.scenes[0].heading == "INT. CAFÉ — DAY")
    }

    @Test func lineLookup() {
        let parsed = ScriptParser.parse("one\ntwo\nthree")
        #expect(parsed.lineIndex(containing: 0) == 0)
        #expect(parsed.lineIndex(containing: 4) == 1)
        #expect(parsed.lineIndex(containing: 13) == 2)
        #expect(ScriptParser.parse("").lines.count == 1)
    }

    @Test func scenesSpanToTheNextHeading() {
        let text = "Preamble.\n\nINT. A {#s1}\n\nOne.\n\nINT. B {#s2}\n\nTwo.\n"
        let parsed = ScriptParser.parse(text)
        let ns = text as NSString
        #expect(parsed.scenes.map(\.sceneID) == ["s1", "s2"])
        #expect(ns.substring(with: parsed.scenes[0].range) == "INT. A {#s1}\n\nOne.\n\n")
        #expect(ns.substring(with: parsed.scenes[1].range) == "INT. B {#s2}\n\nTwo.\n")
        #expect(parsed.sceneIndex(containingLine: 0) == nil)
        #expect(parsed.sceneIndex(containingLine: 4) == 0)
        #expect(parsed.sceneIndex(containingLine: 8) == 1)
    }
}

@Suite("ScriptBook")
struct ScriptBookTests {
    @Test func joinsFilesAndNumbersScenes() {
        let book = ScriptBook(texts: [
            ("script/01-act-one.md", "INT. KITCHEN - NIGHT {#s001}\n\nMARA\nHi.\n\nEXT. ROOF - DAY {#s002}\n\nWind."),
            ("script/02-act-two.md", "INT. KITCHEN - DAY {#s003}\n\nMARA\nAgain.\n\nOLDER MARA\nYes."),
        ])
        #expect(book.scenes.map(\.number) == [1, 2, 3])
        #expect(book.scenes.map(\.file) == ["script/01-act-one.md", "script/01-act-one.md", "script/02-act-two.md"])
        #expect(book.sceneIDs == ["s001", "s002", "s003"])
        #expect(book.characters == ["MARA", "OLDER MARA"])
        #expect(book.locations == ["KITCHEN", "ROOF"])
        #expect(book.times == ["DAY", "NIGHT"])
        #expect(book.scenes.allSatisfy { $0.eighths >= 1 })
        #expect(book.wordCount == 20)
    }

    @Test func durationOverrideWins() {
        let book = ScriptBook(texts: [("s.md", ".MONTAGE {#s1 dur=2:30}\n\nThings happen.")])
        #expect(book.scenes[0].duration == 150)
        let plain = ScriptBook(texts: [("s.md", "INT. A {#s1}\n\nThings happen.")])
        #expect(plain.scenes[0].duration == Double(plain.scenes[0].eighths) / 8 * 60)
    }

    @Test func aFullPageIsEightEighths() {
        let action = Array(repeating: "Short line.\n", count: 54).joined()
        let book = ScriptBook(texts: [("s.md", "INT. A {#s1}\n" + action)])
        #expect(book.scenes[0].eighths == 8)
        #expect(ScriptEstimate.formatEighths(11) == "1 3/8")
        #expect(ScriptEstimate.formatEighths(3) == "3/8")
        #expect(ScriptEstimate.formatEighths(16) == "2")
        #expect(ScriptEstimate.formatDuration(150) == "2:30")
        #expect(ScriptEstimate.formatDuration(3720) == "1:02:00")
    }

    @Test func nextSceneID() {
        #expect(ScriptBook.nextSceneID(existing: []) == "s001")
        #expect(ScriptBook.nextSceneID(existing: ["s014", "s003", "custom"]) == "s015")
        #expect(ScriptBook.nextSceneID(existing: ["s999"]) == "s1000")
    }

    @Test func scriptFilesExcludeTitlePageAndSubfolders() {
        let files = ["script/title-page.md", "script/02-b.md", "script/01-a.md", "script/margin/todos.md", "script/notes.png", "script/10-c.fountain"]
            .map { ProjectFile(relativePath: $0, area: .script) }
        #expect(ScriptBook.scriptFiles(in: files).map(\.name) == ["01-a.md", "02-b.md", "10-c.fountain"])
    }
}
