import Foundation
import Testing
@testable import SlateCore

@Suite("Tab and Return")
struct ScriptEditingTests {
    @Test func returnFollowsFinalDraft() {
        #expect(ScriptEditing.returnPlan(for: .sceneHeading, lineIsEmpty: false) == .init(insert: "\n\n", next: .action))
        #expect(ScriptEditing.returnPlan(for: .action, lineIsEmpty: false) == .init(insert: "\n\n", next: .action))
        #expect(ScriptEditing.returnPlan(for: .character, lineIsEmpty: false) == .init(insert: "\n", next: .dialogue))
        #expect(ScriptEditing.returnPlan(for: .parenthetical, lineIsEmpty: false) == .init(insert: "\n", next: .dialogue))
        #expect(ScriptEditing.returnPlan(for: .dialogue, lineIsEmpty: false) == .init(insert: "\n\n", next: .action))
        #expect(ScriptEditing.returnPlan(for: .transition, lineIsEmpty: false) == .init(insert: "\n\n", next: .sceneHeading))
        #expect(ScriptEditing.returnPlan(for: .boneyard, lineIsEmpty: false) == nil)
    }

    @Test func returnOnAnEmptyElement() {
        // An empty cue or heading turns back into action where it is.
        #expect(ScriptEditing.returnPlan(for: .character, lineIsEmpty: true) == .init(insert: "", next: .action))
        #expect(ScriptEditing.returnPlan(for: .sceneHeading, lineIsEmpty: true) == .init(insert: "", next: .action))
        // Empty dialogue ends the speech.
        #expect(ScriptEditing.returnPlan(for: .dialogue, lineIsEmpty: true) == .init(insert: "\n", next: .action))
    }

    @Test func tabCycles() {
        #expect(ScriptEditing.tab(from: .action, inSpeech: false, forward: true) == .character)
        #expect(ScriptEditing.tab(from: .character, inSpeech: false, forward: true) == .transition)
        #expect(ScriptEditing.tab(from: .transition, inSpeech: false, forward: true) == .sceneHeading)
        #expect(ScriptEditing.tab(from: .sceneHeading, inSpeech: false, forward: true) == .action)
        #expect(ScriptEditing.tab(from: .action, inSpeech: false, forward: false) == .sceneHeading)
        #expect(ScriptEditing.tab(from: .blank, inSpeech: false, forward: true) == .character)
        #expect(ScriptEditing.tab(from: .dialogue, inSpeech: true, forward: true) == .parenthetical)
        #expect(ScriptEditing.tab(from: .parenthetical, inSpeech: true, forward: true) == .dialogue)
        #expect(ScriptEditing.tab(from: .blank, inSpeech: true, forward: true) == .parenthetical)
        #expect(ScriptEditing.tab(from: .boneyard, inSpeech: false, forward: true) == nil)
    }

    @Test(arguments: [
        ("she runs", ScriptElementKind.character, "SHE RUNS"),
        ("mara", .sceneHeading, ".MARA"),
        ("int. hall", .sceneHeading, "INT. HALL"),
        ("INT. KITCHEN {#s014}", .action, "!INT. KITCHEN"),
        (".the void {#s2}", .action, "the void"),
        ("MARA", .transition, ">MARA"),
        ("cut to:", .transition, "CUT TO:"),
        (">FADE OUT.", .action, "!FADE OUT."),
        ("quietly", .parenthetical, "(quietly)"),
        ("(quietly)", .dialogue, "quietly"),
        ("", .parenthetical, "()"),
        ("MARA", .action, "!MARA"),
        ("1998", .character, "@1998"),
    ])
    func conversions(_ line: String, _ kind: ScriptElementKind, _ expected: String) {
        #expect(ScriptEditing.convert(line, to: kind) == expected)
    }

    @Test func convertedLinesParseAsTheTargetKind() {
        for (line, kind) in [("she runs", ScriptElementKind.character), ("MARA", .transition), ("hall", .sceneHeading), ("INT. HALL", .action)] {
            let converted = ScriptEditing.convert(line, to: kind)
            let text = "\n" + converted + (kind == .character ? "\nHi." : "")
            #expect(ScriptParser.parse(text).lines[1].kind == kind, "\(converted)")
        }
    }

    @Test func markersAndCapitals() {
        #expect(ScriptEditing.marker(forTypingInto: .sceneHeading) == "")
        #expect(ScriptEditing.marker(forTypingInto: .transition) == ">")
        #expect(ScriptEditing.marker(forTypingInto: .character) == "")
        #expect(ScriptEditing.typesInCapitals(.character))
        #expect(!ScriptEditing.typesInCapitals(.dialogue))
    }

    @Test func headingMarkersFollowFountain() {
        func fixed(_ text: String, line: Int) -> String {
            let parsed = ScriptParser.parse(text, hint: .init(line: line, kind: .sceneHeading))
            guard let edit = ScriptEditing.headingMarkerEdit(in: parsed, line: line) else { return text }
            return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }
        #expect(fixed("Action.\n\nTHE VAULT", line: 2) == "Action.\n\n.THE VAULT")
        #expect(fixed("Action.\n\nINT. VAULT", line: 2) == "Action.\n\nINT. VAULT")
        #expect(fixed("Action.\n\n.INT. VAULT", line: 2) == "Action.\n\nINT. VAULT")
        #expect(fixed("Action.\nINT. VAULT", line: 1) == "Action.\n.INT. VAULT")
        #expect(fixed("Action.\n\n", line: 2) == "Action.\n\n")
        #expect(fixed("Action.\n\nint. vault {#s001}", line: 2) == "Action.\n\nINT. VAULT {#s001}")
    }

    @Test func missingTagsAreAppended() {
        let text = "INT. A\n\nOne.\n\nINT. B {#s004}\n\nTwo.\n\n.  \n"
        let result = ScriptEditing.assigningSceneIDs(to: text, existing: ["s007"])
        #expect(result == "INT. A {#s008}\n\nOne.\n\nINT. B {#s004}\n\nTwo.\n\n.  \n")
    }

    @Test func duplicateTagsAreReplaced() {
        let text = "INT. A {#s001}\n\nINT. A AGAIN {#s001}\n"
        #expect(ScriptEditing.assigningSceneIDs(to: text) == "INT. A {#s001}\n\nINT. A AGAIN {#s002}\n")
    }

    @Test func onlyLineLimitsTagging() {
        let parsed = ScriptParser.parse("INT. A\n\nINT. B\n")
        let edits = ScriptEditing.missingSceneTags(in: parsed, existing: [], onlyLine: 2)
        #expect(edits.map(\.sceneID) == ["s001"])
        #expect(edits[0].range == NSRange(location: 14, length: 0))
    }

    @Test func movingScenes() {
        let text = "Title card.\n\nINT. A {#s1}\n\nOne.\n\nINT. B {#s2}\n\nTwo.\n\nINT. C {#s3}\nThree."
        let movedDown = ScriptEditing.movingScene(in: text, from: 0, to: 2)
        #expect(movedDown == "Title card.\n\nINT. B {#s2}\n\nTwo.\n\nINT. A {#s1}\n\nOne.\n\nINT. C {#s3}\nThree.\n")
        let movedUp = ScriptEditing.movingScene(in: text, from: 2, to: 0)
        #expect(ScriptParser.parse(movedUp).scenes.map(\.sceneID) == ["s3", "s1", "s2"])
        #expect(ScriptEditing.movingScene(in: text, from: 1, to: 1) == text)
        #expect(ScriptEditing.movingScene(in: text, from: 1, to: 2) == text)
    }
}

@Suite("Autocomplete")
struct ScriptCompletionTests {
    let sources = ScriptCompletion.Sources(characters: ["MARA", "OLDER MARA", "MCCOY"], locations: ["KITCHEN", "KEY ROOM"], times: ["NIGHT"])

    @Test func characterNames() {
        #expect(ScriptCompletion.completion(afterTyping: "M", in: .character, sources: sources) == "ARA")
        #expect(ScriptCompletion.completion(afterTyping: "MC", in: .character, sources: sources) == "COY")
        #expect(ScriptCompletion.completion(afterTyping: "OL", in: .character, sources: sources) == "DER MARA")
        #expect(ScriptCompletion.completion(afterTyping: "MARA", in: .character, sources: sources) == nil)
        #expect(ScriptCompletion.completion(afterTyping: "Z", in: .character, sources: sources) == nil)
        #expect(ScriptCompletion.completion(afterTyping: "MARA (V", in: .character, sources: sources) == ".O.)")
        #expect(ScriptCompletion.completion(afterTyping: "MARA (C", in: .character, sources: sources) == "ONT'D)")
        #expect(ScriptCompletion.completion(afterTyping: "M", in: .dialogue, sources: sources) == nil)
    }

    @Test func headings() {
        #expect(ScriptCompletion.completion(afterTyping: ".I", in: .sceneHeading, sources: sources) == "NT. ")
        #expect(ScriptCompletion.completion(afterTyping: "INT./", in: .sceneHeading, sources: sources) == "EXT. ")
        #expect(ScriptCompletion.completion(afterTyping: ".E", in: .sceneHeading, sources: sources) == "XT. ")
        #expect(ScriptCompletion.completion(afterTyping: "INT. K", in: .sceneHeading, sources: sources) == "ITCHEN")
        #expect(ScriptCompletion.completion(afterTyping: "INT. KE", in: .sceneHeading, sources: sources) == "Y ROOM")
        #expect(ScriptCompletion.completion(afterTyping: "INT. KITCHEN - N", in: .sceneHeading, sources: sources) == "IGHT")
        #expect(ScriptCompletion.completion(afterTyping: "INT. KITCHEN - D", in: .sceneHeading, sources: sources) == "AY")
        #expect(ScriptCompletion.completion(afterTyping: "INT. KITCHEN - ", in: .sceneHeading, sources: sources) == nil)
        #expect(ScriptCompletion.completion(afterTyping: ".", in: .sceneHeading, sources: sources) == nil)
        #expect(ScriptCompletion.completion(afterTyping: "INT. K", in: .sceneHeading, sources: sources) == "ITCHEN")
    }
}

@Suite("Spelling")
struct ScriptSpellingTests {
    @Test func ignoredWordsCoverNamesAndTerms() {
        let words = ScriptSpelling.ignoredWords(characters: ["OLDER MARA", "MCCOY"], extra: ["chronoshift"])
        #expect(words.contains("MARA"))
        #expect(words.contains("Mara"))
        #expect(words.contains("Mccoy"))
        #expect(words.contains("chronoshift"))
        #expect(words.contains("CONT'D"))
        #expect(ScriptSpelling.isScreenplayTerm("ecu"))
    }

    @Test func protectedRangesCoverTagsMarkersAndLinks() {
        let text = ".KITCHEN {#s014}\n\nSee [[The Brass Key]] now."
        let parsed = ScriptParser.parse(text)
        let ns = text as NSString
        let protected = ScriptSpelling.protectedRanges(in: parsed, text: text).map { ns.substring(with: $0) }
        #expect(protected.contains(" {#s014}"))
        #expect(protected.contains("."))
        #expect(protected.contains("[[The Brass Key]]"))
    }

    @Test func wordList() {
        #expect(ScriptSpelling.words(fromWordList: "chronoshift\n\n# comment\n  Voss  \n") == ["chronoshift", "Voss"])
    }

    @Test func characterNoteNames() throws {
        let note = try String(contentsOf: Fixtures.sampleProject.appending(path: "universe/characters/mara-voss.md"), encoding: .utf8)
        #expect(CharacterNotes.names(inNote: note) == ["Mara Voss", "Mara", "The Courier"])
        #expect(CharacterNotes.names(inNote: "---\nname: \"Old Tom\"\naliases:\n  - Tom\n  - 'T'\n---\nBody") == ["Old Tom", "Tom", "T"])
        #expect(CharacterNotes.names(inNote: "No frontmatter") == [])
    }
}
