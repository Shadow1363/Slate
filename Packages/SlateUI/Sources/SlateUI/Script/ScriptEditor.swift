import AppKit
import SlateCore
import SwiftUI

/// The screenplay editor: an `NSTextView` (TextKit 2) over the plain
/// Fountain text, styled per element as you type.
struct ScriptEditor: NSViewRepresentable {
    let document: TextDocument
    /// Passed separately so SwiftUI calls `updateNSView` when it changes.
    let text: String
    let workspace: ScriptWorkspace
    let reveal: RevealRequest?
    let theme: ResolvedTheme
    let sources: ScriptCompletion.Sources
    let ignoredWords: [String]

    func makeCoordinator() -> ScriptEditorController {
        ScriptEditorController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeView(for: self)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ScriptEditorController) {
        coordinator.teardown()
    }
}

@MainActor
final class ScriptEditorController: NSObject, NSTextViewDelegate {
    private var config: ScriptEditor!
    private var scrollView: NSScrollView!
    private(set) var textView: SlateTextView!
    /// `[[` autocomplete over the project's notes.
    let linkCompletion = LinkCompletion()

    private var parsed = ParsedScript.empty
    private var protectedRanges: [NSRange] = []
    /// What the caret's line is being typed as (see `ScriptParser.Hint`).
    private var hint: ScriptParser.Hint?
    private var caretLine = 0
    /// The grey type-ahead text after the caret, selected so typing replaces it.
    private var suggestion: NSRange?
    private var wantsCompletion = false
    /// True while the controller itself edits the text.
    private var programmatic = false
    /// True between a user edit starting and `textDidChange`, when `parsed` is stale.
    private var editPending = false

    private var styled: [LineSignature] = []
    private var attributeCache: [ScriptElementKind: [NSAttributedString.Key: Any]] = [:]
    private var appliedTheme: ResolvedTheme?
    private var lastIgnoredWords: [String] = []
    private var lastRevealToken: UUID?
    /// The text the editor last handed to the document (same storage, so
    /// comparing against it is cheap).
    private var syncedText = ""
    private var frameObserver: (any NSObjectProtocol)?

    private struct LineSignature: Equatable {
        let kind: ScriptElementKind
        let text: String
    }

    private var theme: ResolvedTheme { config.theme }
    private var path: String { config.document.relativePath }

    // MARK: - Setup

    func makeView(for config: ScriptEditor) -> NSScrollView {
        self.config = config
        let (scrollView, textView) = SlateTextView.scrollable()
        scrollView.drawsBackground = true
        self.scrollView = scrollView
        self.textView = textView

        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.postsFrameChangedNotifications = true
        textView.setAccessibilityLabel("Script")
        textView.followLink = { [weak self] target in self?.config.workspace.followLink(target) ?? false }
        textView.insertLinkAction = { [weak self] in
            guard let self else { return }
            self.linkCompletion.insertLink(in: self.textView)
        }
        linkCompletion.graph = { [weak self] in self?.config.workspace.linkGraph() ?? .empty }

        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutColumn() }
        }

        textView.string = config.text
        syncedText = config.text
        applyTheme()
        reparse()
        restyle(force: true)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        updateTypingAttributes()

        DispatchQueue.main.async { [weak textView] in
            guard let textView, textView.window?.firstResponder !== textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func teardown() {
        linkCompletion.hide()
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
    }

    func update(from config: ScriptEditor) {
        self.config = config
        guard let textView else { return }

        if config.text != syncedText, config.text != nativeText() {
            // Reloaded from disk, or a scene was moved in the navigator.
            hint = nil
            suggestion = nil
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            let selection = textView.selectedRange()
            let length = (config.text as NSString).length
            let location = min(selection.location, length)
            replace(full, with: config.text, selection: NSRange(location: location, length: 0))
        }
        if appliedTheme != config.theme {
            applyTheme()
            restyle(force: true)
            updateTypingAttributes()
        }
        if lastIgnoredWords != config.ignoredWords {
            lastIgnoredWords = config.ignoredWords
            NSSpellChecker.shared.setIgnoredWords(config.ignoredWords, inSpellDocumentWithTag: textView.spellCheckerDocumentTag)
        }
        if let reveal = config.reveal, reveal.token != lastRevealToken, reveal.file == path {
            lastRevealToken = reveal.token
            perform(reveal)
        }
    }

    private func perform(_ reveal: RevealRequest) {
        let length = (textView.string as NSString).length
        let location = min(reveal.location, length)
        programmatic = true
        textView.setSelectedRange(NSRange(location: location, length: 0))
        programmatic = false
        caretMoved()
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        if reveal.focus { textView.window?.makeFirstResponder(textView) }
    }

    // MARK: - Theme and layout

    private func applyTheme() {
        appliedTheme = theme
        attributeCache = [:]
        let background = NSColor(theme.editor.background)
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.insertionPointColor = NSColor(theme.editor.caret)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(theme.editor.selection)]
        layoutColumn()
    }

    /// One inch of page at the theme's script size: Courier sets 10
    /// characters per inch at 12 pt, so an inch is 6 × the point size.
    private var inch: CGFloat { CGFloat(theme.script.action.size) * 6 }

    /// Keeps a 6-inch text column centred in the view.
    private func layoutColumn() {
        guard let textView else { return }
        let column = inch * 6
        let side = max(20, ((textView.frame.width - column) / 2).rounded(.down))
        if textView.textContainerInset.width != side {
            textView.textContainerInset = NSSize(width: side, height: 32)
        }
        if textView.textContainer?.size.width != column {
            textView.textContainer?.size = NSSize(width: column, height: .greatestFiniteMagnitude)
        }
    }

    private func style(for kind: ScriptElementKind) -> ResolvedTheme.ElementStyle {
        switch kind {
        case .sceneHeading: theme.script.sceneHeading
        case .action, .blank: theme.script.action
        case .character: theme.script.character
        case .parenthetical: theme.script.parenthetical
        case .dialogue, .lyric: theme.script.dialogue
        case .transition: theme.script.transition
        case .centered: theme.script.centered
        case .boneyard, .synopsis, .pageBreak: theme.script.boneyard
        }
    }

    /// Left and right edges in inches from the start of the 6-inch column
    /// (the page's 1.5" left margin), from SPEC.md › Publish.
    private func edges(for kind: ScriptElementKind) -> (CGFloat, CGFloat) {
        switch kind {
        case .character: (2.2, 6)
        case .parenthetical: (1.6, 3.6)
        case .dialogue, .lyric: (1.0, 4.5)
        default: (0, 6)
        }
    }

    private func attributes(for kind: ScriptElementKind) -> [NSAttributedString.Key: Any] {
        if let cached = attributeCache[kind] { return cached }
        let style = style(for: kind)
        var font = NSFont.slate(style.font, size: style.size, weight: style.weight)
        if kind == .boneyard || kind == .synopsis || kind == .lyric {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = theme.editor.lineSpacing
        let (left, right) = edges(for: kind)
        paragraph.firstLineHeadIndent = left * inch
        paragraph.headIndent = left * inch
        paragraph.tailIndent = right * inch
        switch kind {
        case .transition: paragraph.alignment = .right
        case .centered: paragraph.alignment = .center
        default: paragraph.alignment = .left
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(style.color),
            .paragraphStyle: paragraph,
        ]
        attributeCache[kind] = attributes
        return attributes
    }

    // MARK: - Parsing and styling

    /// The text view's string as a native Swift string. Bridged strings
    /// compare and index slowly, which adds up on every keystroke.
    private func nativeText() -> String {
        var text = textView.string
        text.makeContiguousUTF8()
        return text
    }

    private func reparse(_ current: String? = nil) {
        let text = current ?? nativeText()
        parsed = ScriptParser.parse(text, hint: hint)
        protectedRanges = ScriptSpelling.protectedRanges(in: parsed, text: text)
        editPending = false
        if hint == nil { config.workspace.cache(parsed, text: text, for: path) }
    }

    /// Restyles the lines that changed since the last pass (all of them if forced).
    private func restyle(force: Bool) {
        guard let storage = textView.textStorage else { return }
        let signatures = parsed.lines.map { LineSignature(kind: $0.kind, text: $0.text) }
        var start = 0
        var oldEnd = styled.count
        var newEnd = signatures.count
        if !force {
            while start < oldEnd, start < newEnd, styled[start] == signatures[start] { start += 1 }
            while oldEnd > start, newEnd > start, styled[oldEnd - 1] == signatures[newEnd - 1] {
                oldEnd -= 1
                newEnd -= 1
            }
        }
        styled = signatures
        guard start < newEnd else { return }

        let faint = NSColor(theme.script.boneyard.color)
        let chip = theme.script.sceneChip
        let chipFont = NSFont.slate(chip.font, size: chip.size, weight: chip.weight)
        let link = NSColor(theme.markdown.wikiLink)
        storage.beginEditing()
        for line in parsed.lines[start..<newEnd] where line.paragraphRange.length > 0 {
            storage.setAttributes(attributes(for: line.kind), range: line.paragraphRange)
            if line.markerLength > 0 {
                storage.addAttribute(.foregroundColor, value: faint, range: NSRange(location: line.range.location, length: line.markerLength))
            }
            if let tag = line.tagRange {
                storage.addAttributes([
                    .font: chipFont,
                    .foregroundColor: NSColor(chip.color),
                    .backgroundColor: NSColor(chip.color).withAlphaComponent(0.12),
                ], range: tag)
            }
            if line.text.contains("[[") {
                for found in WikiLink.find(in: line.text) {
                    storage.addAttributes([
                        .foregroundColor: link,
                        .slateLinkTarget: found.target,
                    ], range: NSRange(location: line.range.location + found.range.location, length: found.range.length))
                }
            }
        }
        storage.endEditing()
    }

    private func updateTypingAttributes() {
        let location = textView.selectedRange().location
        guard let line = parsed.line(containing: location) else { return }
        textView.typingAttributes = attributes(for: line.kind)
    }

    private func refresh() {
        reparse()
        restyle(force: false)
        updateTypingAttributes()
        publishCaret()
    }

    // MARK: - Editing helpers

    /// Replaces text as one undoable edit and sets the selection.
    private func replace(_ range: NSRange, with string: String, selection: NSRange) {
        let ns = textView.string as NSString
        guard range.upperBound <= ns.length else { return }
        if ns.substring(with: range) == string {
            select(selection)
            refresh()
            return
        }
        programmatic = true
        guard textView.shouldChangeText(in: range, replacementString: string) else {
            programmatic = false
            return
        }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.setSelectedRange(selection)
        programmatic = false
        textView.didChangeText()
    }

    private func select(_ range: NSRange) {
        programmatic = true
        textView.setSelectedRange(range)
        programmatic = false
        caretLine = parsed.lineIndex(containing: range.location)
    }

    private func acceptSuggestion() {
        guard let suggestion else { return }
        self.suggestion = nil
        select(NSRange(location: suggestion.upperBound, length: 0))
    }

    private func removeSuggestion(keeping selection: NSRange) {
        guard let suggestion else { return }
        self.suggestion = nil
        var target = selection
        if target.location >= suggestion.upperBound {
            target.location -= suggestion.length
        } else if target.location > suggestion.location {
            target = NSRange(location: suggestion.location, length: 0)
        }
        replace(suggestion, with: "", selection: target)
    }

    private func offerCompletion() {
        let selection = textView.selectedRange()
        guard selection.length == 0, let line = parsed.line(containing: selection.location),
              line.kind == .character || line.kind == .sceneHeading,
              line.tagRange == nil, selection.location == line.range.upperBound,
              let rest = ScriptCompletion.completion(afterTyping: line.text, in: line.kind, sources: config.sources)
        else { return }
        let range = NSRange(location: selection.location, length: rest.utf16.count)
        replace(NSRange(location: selection.location, length: 0), with: rest, selection: range)
        suggestion = range
    }

    /// Gives the heading on `index` a scene tag if it has none (or a duplicate).
    private func commitSceneTag(line index: Int) {
        guard parsed.lines.indices.contains(index), parsed.lines[index].kind == .sceneHeading else { return }
        let existing = config.workspace.sceneIDs(excluding: path)
        guard let edit = ScriptEditing.missingSceneTags(in: parsed, existing: existing, onlyLine: index).first else { return }
        var selection = textView.selectedRange()
        if selection.location >= edit.range.upperBound {
            selection.location += edit.replacement.utf16.count - edit.range.length
        }
        replace(edit.range, with: edit.replacement, selection: selection)
    }

    // MARK: - Return and Tab

    private func handleReturn() -> Bool {
        acceptSuggestion()
        let selection = textView.selectedRange()
        guard selection.length == 0, var line = parsed.line(containing: selection.location) else { return false }

        var caret = selection.location
        if line.kind == .parenthetical, line.text.hasSuffix(")"), caret == line.range.upperBound - 1 {
            caret = line.range.upperBound
        }
        let endOfText = line.tagRange?.location ?? line.range.upperBound
        guard caret >= endOfText else {
            hint = nil
            return false // Mid-line: an ordinary line break.
        }

        if line.kind == .parenthetical, line.text.trimmingCharacters(in: .whitespaces) == "()" {
            hint = .init(line: line.index, kind: .dialogue)
            replace(line.range, with: "", selection: NSRange(location: line.range.location, length: 0))
            return true
        }
        if line.kind == .sceneHeading, !line.isEmpty {
            commitSceneTag(line: line.index)
            line = parsed.lines[line.index]
        }

        let isEmpty = ScriptEstimate.printedText(of: line).isEmpty && line.kind != .parenthetical
        guard let plan = ScriptEditing.returnPlan(for: line.kind, lineIsEmpty: isEmpty) else {
            hint = nil
            return false
        }
        if plan.insert.isEmpty {
            // An empty cue or heading: turn this line into the next kind.
            hint = .init(line: line.index, kind: plan.next)
            replace(line.range, with: "", selection: NSRange(location: line.range.location, length: 0))
            return true
        }
        let newLine = line.index + plan.insert.filter(\.isNewline).count
        hint = .init(line: newLine, kind: plan.next)
        let end = line.range.upperBound
        replace(NSRange(location: end, length: 0), with: plan.insert, selection: NSRange(location: end + plan.insert.utf16.count, length: 0))
        return true
    }

    private func handleTab(forward: Bool) -> Bool {
        if suggestion != nil {
            acceptSuggestion()
            return true
        }
        let selection = textView.selectedRange()
        guard let line = parsed.line(containing: selection.location) else { return true }
        let previous = line.index > 0 ? parsed.lines[line.index - 1].kind : .blank
        guard let target = ScriptEditing.tab(from: line.kind, inSpeech: previous.isSpeech, forward: forward) else { return true }

        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        let isEmpty = ScriptEstimate.printedText(of: line).isEmpty || trimmed == "()"
        hint = .init(line: line.index, kind: target)
        let newText = isEmpty ? (target == .parenthetical ? "()" : "") : ScriptEditing.convert(line.text, to: target)
        var caret = line.range.location + (newText as NSString).length
        if target == .parenthetical, newText.hasSuffix(")") { caret -= 1 }
        replace(line.range, with: newText, selection: NSRange(location: caret, length: 0))
        return true
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
        if programmatic { return true }
        editPending = true
        wantsCompletion = false
        guard let string, !string.isEmpty, !textView.hasMarkedText(), !string.contains(where: \.isNewline),
              let line = parsed.line(containing: range.location)
        else {
            if string?.isEmpty == true, let suggestion, range == suggestion { self.suggestion = nil }
            return true
        }
        suggestion = nil
        if let tag = line.tagRange, range.location > tag.location || NSIntersectionRange(tag, range).length > 0 {
            return true // Typing inside a scene tag: leave it alone.
        }

        let kind = line.kind
        let text = ScriptEditing.typesInCapitals(kind) ? string.uppercased() : string
        let marker = line.range.length == 0 ? ScriptEditing.marker(forTypingInto: kind) : ""
        wantsCompletion = (kind == .character || kind == .sceneHeading) && range.upperBound == line.range.upperBound && line.tagRange == nil
        if marker.isEmpty, text == string { return true }

        // Insert through the normal typing path so undo still groups keystrokes.
        programmatic = true
        textView.insertText(marker + text, replacementRange: range)
        programmatic = false
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        let text = nativeText()
        syncedText = text
        config.document.text = text

        reparse(text)
        let line = parsed.lineIndex(containing: textView.selectedRange().location)
        if let hint, hint.line != line {
            self.hint = nil
            reparse(text)
        }
        caretLine = line
        restyle(force: false)
        updateTypingAttributes()
        publishCaret()

        if wantsCompletion {
            wantsCompletion = false
            offerCompletion()
        }
        linkCompletion.update(in: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !programmatic, !editPending, textView != nil else { return }
        let selection = textView.selectedRange()
        if let suggestion, selection != suggestion {
            if selection == NSRange(location: suggestion.upperBound, length: 0) {
                self.suggestion = nil
            } else {
                DispatchQueue.main.async { [weak self] in self?.removeSuggestion(keeping: selection) }
                return
            }
        }
        caretMoved()
        linkCompletion.update(in: textView)
    }

    /// Clears a stale hint and tags the heading the caret just left.
    private func caretMoved() {
        let line = parsed.lineIndex(containing: textView.selectedRange().location)
        if line != caretLine {
            let left = caretLine
            caretLine = line
            if let hint, hint.line != line {
                self.hint = nil
                refresh()
            }
            commitSceneTag(line: left)
        }
        updateTypingAttributes()
        publishCaret()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if linkCompletion.handle(selector) { return true }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return handleReturn()
        case #selector(NSResponder.insertTab(_:)):
            return handleTab(forward: true)
        case #selector(NSResponder.insertBacktab(_:)):
            return handleTab(forward: false)
        case #selector(NSResponder.cancelOperation(_:)):
            guard suggestion != nil else { return false }
            removeSuggestion(keeping: textView.selectedRange())
            return true
        default:
            return false
        }
    }

    /// Drops spelling flags on scene tags, markers, links and screenplay terms.
    func textView(
        _ view: NSTextView,
        didCheckTextIn range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:],
        results: [NSTextCheckingResult],
        orthography: NSOrthography,
        wordCount: Int
    ) -> [NSTextCheckingResult] {
        let ns = view.string as NSString
        return results.filter { result in
            guard result.resultType == .spelling else { return true }
            if protectedRanges.contains(where: { NSIntersectionRange($0, result.range).length > 0 }) { return false }
            if result.range.upperBound <= ns.length, ScriptSpelling.isScreenplayTerm(ns.substring(with: result.range)) { return false }
            return true
        }
    }

    // MARK: - Caret reporting

    private func publishCaret() {
        let location = textView.selectedRange().location
        let line = parsed.lineIndex(containing: location)
        let caret = ScriptCaret(
            file: path,
            location: location,
            kind: parsed.lines.indices.contains(line) ? parsed.lines[line].kind : .action,
            sceneIndex: parsed.sceneIndex(containingLine: line)
        )
        let workspace = config.workspace
        // Deferred: this can run inside a SwiftUI view update.
        DispatchQueue.main.async {
            if workspace.caret != caret { workspace.caret = caret }
        }
    }
}
