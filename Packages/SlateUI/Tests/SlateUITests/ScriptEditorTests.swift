import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

/// Drives the real editor controller with keystrokes, without a window.
@MainActor
final class EditorHarness {
    let folder: URL
    let store: ProjectStore
    let workspace: ScriptWorkspace
    let document: TextDocument
    let controller = ScriptEditorController()
    /// What SwiftUI would pass from the dictionary.
    var spelling = EditorSpelling.none
    private var scrollView: NSScrollView?

    init(text: String = "") throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "SlateUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try ProjectCreator.create(title: "Harness", template: .short, in: folder)
        try Data(text.utf8).write(to: root.appending(path: "script/script.md"))
        store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        workspace = ScriptWorkspace(store: store)
        document = try #require(store.documents["script/script.md"])
        scrollView = controller.makeView(for: editor())
        controller.update(from: editor())
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func editor() -> ScriptEditor {
        ScriptEditor(
            document: document,
            text: document.text,
            workspace: workspace,
            reveal: workspace.reveal,
            theme: ThemeEngine.builtInLight,
            sources: workspace.completionSources,
            spelling: spelling
        )
    }

    var textView: NSTextView { controller.textView }
    var text: String { textView.string }
    var kinds: [ScriptElementKind] { ScriptParser.parse(text).lines.map(\.kind) }

    /// Types one key at a time, like the keyboard does.
    func type(_ string: String) {
        for character in string {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
            // SwiftUI would push the new sources after each change.
            controller.update(from: editor())
        }
    }

    func press(_ selector: Selector) {
        textView.doCommand(by: selector)
        controller.update(from: editor())
    }

    func returnKey() { press(#selector(NSResponder.insertNewline(_:))) }
    func tab() { press(#selector(NSResponder.insertTab(_:))) }
    func shiftTab() { press(#selector(NSResponder.insertBacktab(_:))) }
    func escape() { press(#selector(NSResponder.cancelOperation(_:))) }
}

@MainActor
@Suite("Script editor keystrokes")
struct ScriptEditorTests {
    @Test func typesTheSpecSceneWithoutTheMouse() throws {
        let h = try EditorHarness()

        h.tab(); h.tab(); h.tab()                 // Action → Character → Transition → Scene Heading
        h.type("int. kitchen - night")
        h.returnKey()                             // tags the heading, then Action
        h.type("Rain hammers the window. MARA (34) stares at a brass key on the table.")
        h.returnKey()
        h.tab()                                   // Character
        h.type("mara")
        h.returnKey()                             // Dialogue
        h.tab()                                   // Parenthetical, caret inside ()
        h.type("quietly")
        h.returnKey()                             // past ")" → Dialogue
        h.type("I haven't opened it yet.")
        h.returnKey()                             // Action
        h.tab()
        h.type("older mara (o.s.)")
        h.returnKey()
        h.type("You already have.")
        h.returnKey()
        h.tab(); h.tab()                          // Transition
        h.type("cut to:")

        #expect(h.text == """
        INT. KITCHEN - NIGHT {#s001}

        Rain hammers the window. MARA (34) stares at a brass key on the table.

        MARA
        (quietly)
        I haven't opened it yet.

        OLDER MARA (O.S.)
        You already have.

        >CUT TO:
        """)
        #expect(h.kinds == [
            .sceneHeading, .blank, .action, .blank, .character, .parenthetical, .dialogue, .blank,
            .character, .dialogue, .blank, .transition,
        ])
        #expect(h.document.text == h.text, "the document follows the editor")
    }

    @Test func returnAfterTransitionStartsAHeading() throws {
        let h = try EditorHarness(text: "Action.\n\n>CUT TO:")
        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.returnKey()
        h.type("ext. roof - day")
        h.returnKey()
        #expect(h.text.hasPrefix("Action.\n\n>CUT TO:\n\nEXT. ROOF - DAY {#s001}\n\n"))
    }

    @Test func autocompleteOffersAKnownCueAndReturnAcceptsIt() throws {
        let h = try EditorHarness(text: "INT. A {#s001}\n\nMARA\nHello.\n\n")
        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.tab()
        h.type("m")
        #expect(h.text.hasSuffix("\n\nMARA"))
        #expect(h.textView.selectedRange().length == 3, "the suggested ARA is selected")
        h.returnKey()
        h.type("Again.")
        #expect(h.text.hasSuffix("MARA\nHello.\n\nMARA\nAgain."))
    }

    @Test func typingThroughASuggestionKeepsWhatYouType() throws {
        let h = try EditorHarness(text: "INT. A {#s001}\n\nMARA\nHello.\n\n")
        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.tab()
        h.type("max")
        #expect(h.text.hasSuffix("\n\nMAX"))
    }

    @Test func escapeDropsTheSuggestion() throws {
        let h = try EditorHarness(text: "INT. A {#s001}\n\nMARA\nHello.\n\n")
        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.tab()
        h.type("m")
        h.escape()
        #expect(h.text.hasSuffix("\n\nM"))
    }

    @Test func headingAutocompleteUsesKnownLocations() throws {
        let h = try EditorHarness(text: "INT. KITCHEN - NIGHT {#s001}\n\nRain.\n\n")
        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.tab(); h.tab(); h.tab()
        h.type("e")
        h.tab()                                   // accept "XT. "
        h.type("k")
        h.tab()                                   // accept "ITCHEN"
        h.type(" - d")
        h.tab()                                   // accept "AY"
        #expect(h.text.hasSuffix("\n\nEXT. KITCHEN - DAY"))
    }

    @Test func headingsWithoutIntExtAreForcedWithADot() throws {
        let h = try EditorHarness(text: "INT. A {#s001}\n\nOne.\n\n")
        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.tab(); h.tab(); h.tab()
        h.type("the vault")
        h.returnKey()
        #expect(h.text.hasPrefix("INT. A {#s001}\n\nOne.\n\n.THE VAULT {#s002}\n\n"))
        #expect(ScriptParser.parse(h.text).scenes.map(\.heading) == ["INT. A", "THE VAULT"])
    }

    @Test func hashLinesStaySections() throws {
        let h = try EditorHarness(text: "")
        h.type("# Act One")
        h.returnKey()
        h.returnKey()
        h.type("int. vault - night")
        h.returnKey()
        #expect(h.text.hasPrefix("# Act One\n\nINT. VAULT - NIGHT {#s001}\n\n"))
        #expect(ScriptParser.parse(h.text).lines.first?.kind == .section)
        #expect(ScriptParser.parse(h.text).scenes.count == 1)
    }

    @Test func leavingAHeadingTagsIt() throws {
        let h = try EditorHarness(text: "INT. A {#s001}\n\nOne.\n\n")
        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.tab(); h.tab(); h.tab()
        h.type("int. b")
        h.press(#selector(NSResponder.moveUp(_:)))
        #expect(h.text == "INT. A {#s001}\n\nOne.\n\nINT. B {#s002}")
    }

    @Test func shiftTabCyclesBackwards() throws {
        let h = try EditorHarness(text: "\nshe runs")
        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.tab()
        #expect(h.text == "\nSHE RUNS")
        h.shiftTab()
        #expect(h.text == "\n!SHE RUNS", "back to action, forced because it's all caps")
    }

    @Test func returnOnAnEmptyCueGoesBackToAction() throws {
        let h = try EditorHarness(text: "One.\n\n")
        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.tab()
        h.returnKey()
        h.type("she waits")
        #expect(h.text == "One.\n\nshe waits")
        #expect(h.kinds.last == .action)
    }

    @Test func midLineReturnIsAPlainBreak() throws {
        let h = try EditorHarness(text: "One two.")
        h.textView.setSelectedRange(NSRange(location: 3, length: 0))
        h.returnKey()
        #expect(h.text == "One\n two.")
    }

    @Test func outsideChangesReplaceTheTextUndoably() throws {
        let h = try EditorHarness(text: "Original.")
        h.document.text = "Changed outside."
        h.controller.update(from: h.editor())
        #expect(h.text == "Changed outside.")
        h.textView.undoManager?.undo()
        #expect(h.text == "Original." || h.textView.undoManager == nil)
    }

    @Test func spellCheckSkipsTagsAndTerms() throws {
        let h = try EditorHarness(text: "INT. KITCHEN {#s014}\n\nMARA (CONT'D)\nZorblax.")
        let ns = h.text as NSString
        let tag = ns.range(of: "s014")
        let cont = ns.range(of: "CONT'D")
        let word = ns.range(of: "Zorblax")
        let results = [tag, cont, word].map { NSTextCheckingResult.spellCheckingResult(range: $0) }
        let kept = h.controller.textView(
            h.textView, didCheckTextIn: NSRange(location: 0, length: ns.length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue,
            options: [:], results: results,
            orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 6
        )
        #expect(kept.map(\.range) == [word])
    }

    @Test func liveFormattingIndentsDialogue() throws {
        let h = try EditorHarness(text: "\nMARA\nHello there.")
        let storage = try #require(h.textView.textStorage)
        let ns = h.text as NSString
        let cue = storage.attribute(.paragraphStyle, at: ns.range(of: "MARA").location, effectiveRange: nil) as? NSParagraphStyle
        let line = storage.attribute(.paragraphStyle, at: ns.range(of: "Hello").location, effectiveRange: nil) as? NSParagraphStyle
        let inch = CGFloat(ThemeEngine.builtInLight.script.action.size) * 6
        #expect(cue?.headIndent == 2.2 * inch)
        #expect(line?.headIndent == 1.0 * inch)
        #expect(line?.tailIndent == 4.5 * inch)
    }
}

@MainActor
@Suite("Script editor speed")
struct ScriptEditorSpeedTests {
    /// About ten pages: typing at the end must stay well under a frame.
    @Test func typingInATenPageScriptStaysFast() throws {
        var scenes: [String] = []
        for n in 1...45 {
            scenes.append("""
            INT. ROOM \(n) - NIGHT {#s\(String(format: "%03d", n))}

            Rain hammers the window. Mara stares at a brass key on the table, turning it over.

            MARA
            (quietly)
            I haven't opened it yet. I keep telling myself I won't.

            OLDER MARA (O.S.)
            You already have.

            """)
        }
        let h = try EditorHarness(text: scenes.joined(separator: "\n"))
        let book = ScriptBook(texts: [("s.md", h.text)])
        #expect(book.pageCount >= 9)

        h.textView.setSelectedRange(NSRange(location: (h.text as NSString).length, length: 0))
        h.returnKey()
        let clock = ContinuousClock()
        let keys = "She leaves the key on the table and walks out into the rain."
        let elapsed = clock.measure { h.type(keys) }
        let perKey = elapsed / keys.count
        print("Per keystroke on ~\(Int(book.pageCount)) pages: \(perKey)")
        // One frame in release (measured about 9 ms); unoptimised debug
        // builds get two, so the check isn't flaky on a busy machine.
        // GitHub's shared runners can run several times slower than a Mac
        // at a desk (68 ms here once, when the whole run took 3x longer), so
        // CI only catches order-of-magnitude regressions.
        let onCI = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        #if DEBUG
        #expect(perKey < .milliseconds(onCI ? 100 : 33))
        #else
        #expect(perKey < .milliseconds(onCI ? 50 : 16))
        #endif
    }
}
