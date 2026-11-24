import AppKit
import SlateCore
import SwiftUI

/// The Markdown editor for notes, the rough draft and margin files: the
/// source stays visible, styled as you type (headings, emphasis, dimmed
/// markers, `[[link]]` chips). For notes it edits only the body; the form
/// above it owns the frontmatter, and both write the same file.
struct MarkdownEditor: NSViewRepresentable {
    let document: TextDocument
    /// Passed separately so SwiftUI calls `updateNSView` when it changes.
    let text: String
    /// Edit only what follows the frontmatter block.
    let hidesFrontmatter: Bool
    let theme: ResolvedTheme
    let reveal: RevealRequest?
    /// Bumped when the link index changes, so link colours update.
    let linkVersion: Int
    let session: ProjectSession?
    /// Spell check for notes, and defined-word underlines.
    var spelling: EditorSpelling = .none

    func makeCoordinator() -> MarkdownEditorController {
        MarkdownEditorController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeView(for: self)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: MarkdownEditorController) {
        coordinator.teardown()
    }
}

@MainActor
final class MarkdownEditorController: NSObject, NSTextViewDelegate {
    private var config: MarkdownEditor!
    private var scrollView: NSScrollView!
    private(set) var textView: SlateTextView!
    let completion = LinkCompletion()

    private struct LineSignature: Equatable {
        let text: String
        let inFence: Bool
    }

    private var styled: [LineSignature] = []
    private var lines: [MarkdownSyntax.Line] = []
    private var lineRanges: [NSRange] = []
    private var protectedRanges: [NSRange] = []
    private var appliedTheme: ResolvedTheme?
    private var appliedLinkVersion = -1
    private var lastRevealToken: UUID?
    /// The whole file as last handed to the document.
    private var syncedText = ""
    /// Comments styled by the last pass, to restore lines that stop being one.
    private var commentRanges: [NSRange] = []
    private var programmatic = false
    private var frameObserver: (any NSObjectProtocol)?
    private(set) var terms: TermDecorator!

    private var theme: ResolvedTheme { config.theme }

    // MARK: - Setup

    func makeView(for config: MarkdownEditor) -> NSScrollView {
        self.config = config
        let (scrollView, textView) = SlateTextView.scrollable()
        self.scrollView = scrollView
        self.textView = textView
        scrollView.drawsBackground = true

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
        textView.textContainer?.lineFragmentPadding = 0
        textView.postsFrameChangedNotifications = true
        textView.setAccessibilityLabel(config.hidesFrontmatter ? "Note body" : "Markdown")
        textView.followLink = { [weak self] target in
            self?.config.session?.followLink(target) ?? false
        }
        textView.insertLinkAction = { [weak self] in
            guard let self else { return }
            self.completion.insertLink(in: self.textView)
        }
        completion.graph = { [weak self] in self?.config.session?.links.graph ?? .empty }
        textView.previewForLink = { [weak self] target in self?.config.session?.linkPreview(target) }
        // Right-click inside a `%% TODO: … %%` comment ticks it.
        textView.extraMenuItems = { [weak textView] index in
            guard let textView else { return [] }
            return CommentTodoEditing.menuItems(at: index, in: textView, script: false)
        }
        terms = TermDecorator(textView: textView)
        terms.protectedRanges = { [weak self] in self?.protectedRanges ?? [] }
        config.session?.dictionaryActions(inScript: false).install(in: textView, decorator: terms)

        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutColumn() }
        }

        syncedText = config.text
        textView.string = editableText(from: config.text)
        applyTheme()
        restyle(force: true)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        appliedLinkVersion = config.linkVersion
        terms.apply(config.spelling, color: NSColor(config.theme.editor.termUnderline))
        return scrollView
    }

    func teardown() {
        completion.hide()
        textView?.closePreview()
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
    }

    func update(from config: MarkdownEditor) {
        self.config = config
        guard let textView else { return }
        if config.text != syncedText {
            syncedText = config.text
            let editable = editableText(from: config.text)
            if editable != textView.string {
                // Reloaded from disk, a rename edited links, or the form changed.
                let selection = textView.selectedRange()
                let length = (editable as NSString).length
                let location = min(selection.location, length)
                let full = NSRange(location: 0, length: (textView.string as NSString).length)
                programmatic = true
                if textView.shouldChangeText(in: full, replacementString: editable) {
                    textView.textStorage?.replaceCharacters(in: full, with: editable)
                    textView.didChangeText()
                }
                textView.setSelectedRange(NSRange(location: location, length: 0))
                programmatic = false
                restyle(force: false)
            }
        }
        if appliedTheme != config.theme {
            applyTheme()
            restyle(force: true)
        }
        terms.apply(config.spelling, color: NSColor(config.theme.editor.termUnderline))
        if appliedLinkVersion != config.linkVersion {
            appliedLinkVersion = config.linkVersion
            restyle(force: true)
        }
        if let reveal = config.reveal, reveal.token != lastRevealToken, reveal.file == config.document.relativePath {
            lastRevealToken = reveal.token
            let offset = config.hidesFrontmatter ? Frontmatter.split(config.document.text).bodyOffset : 0
            textView.reveal(range: NSRange(location: max(0, reveal.location - offset), length: reveal.length), focus: reveal.focus)
        }
    }

    private func editableText(from text: String) -> String {
        config.hidesFrontmatter ? Frontmatter.split(text).body : text
    }

    // MARK: - Theme

    private func applyTheme() {
        appliedTheme = theme
        let background = NSColor(theme.editor.background)
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.insertionPointColor = NSColor(theme.editor.caret)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(theme.editor.selection)]
        textView.typingAttributes = baseAttributes
        layoutColumn()
    }

    /// Keeps a readable column (about 70 characters) centred.
    private func layoutColumn() {
        guard let textView else { return }
        let column = min(CGFloat(theme.markdown.size) * 42, max(textView.frame.width - 48, 200))
        let side = max(24, ((textView.frame.width - column) / 2).rounded(.down))
        if textView.textContainerInset.width != side {
            textView.textContainerInset = NSSize(width: side, height: 24)
        }
    }

    private var bodyFont: NSFont { NSFont.slate(theme.markdown.font, size: theme.markdown.size) }

    private var baseParagraph: NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = theme.editor.lineSpacing
        paragraph.paragraphSpacing = CGFloat(theme.markdown.size) * 0.3
        return paragraph
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor(theme.markdown.text), .paragraphStyle: baseParagraph]
    }

    // MARK: - Styling

    /// Restyles lines that changed since the last pass (all if forced).
    private func restyle(force: Bool) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location <= text.length {
            let end = text.range(of: "\n", range: NSRange(location: location, length: text.length - location)).location
            let lineEnd = end == NSNotFound ? text.length : end
            ranges.append(NSRange(location: location, length: lineEnd - location))
            if end == NSNotFound { break }
            location = lineEnd + 1
        }
        var signatures: [LineSignature] = []
        var scanned: [MarkdownSyntax.Line] = []
        var inFence = false
        for range in ranges {
            let line = text.substring(with: range)
            signatures.append(LineSignature(text: line, inFence: inFence))
            let result = MarkdownSyntax.scan(line: line, inFence: inFence)
            scanned.append(result.line)
            inFence = result.inFence
        }
        lines = scanned
        lineRanges = ranges

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
        protectedRanges = Self.protectedRanges(lines: scanned, ranges: ranges)
        guard start < newEnd else { return }

        storage.beginEditing()
        for index in start..<newEnd {
            // Include the newline so paragraph styles cover the whole paragraph.
            var range = ranges[index]
            if NSMaxRange(range) < text.length { range.length += 1 }
            guard range.length > 0 else { continue }
            style(scanned[index], in: range, storage: storage)
        }
        styleComments(text, storage: storage)
        storage.endEditing()
    }

    /// `%% … %%` and `<!-- … -->` comments, which can span lines: dimmed, with
    /// a `TODO:`/`DONE:` word picked out. Lines that were in a comment and
    /// no longer are get their normal style back.
    private func styleComments(_ text: NSString, storage: NSTextStorage) {
        let found = CommentTodos.noteComments(in: text as String)
        let ranges = found.map(\.range)
        for old in commentRanges where !ranges.contains(old) {
            for (index, lineRange) in lineRanges.enumerated() where index < lines.count {
                var range = lineRange
                if NSMaxRange(range) < text.length { range.length += 1 }
                guard range.length > 0, NSIntersectionRange(range, old).length > 0 || NSLocationInRange(old.location, range) else { continue }
                style(lines[index], in: range, storage: storage)
            }
        }
        commentRanges = ranges
        let markdown = theme.markdown
        for comment in found where NSMaxRange(comment.range) <= text.length {
            storage.addAttribute(.foregroundColor, value: NSColor(markdown.quote).withAlphaComponent(0.75), range: comment.range)
            if let marker = comment.marker, NSMaxRange(marker) <= text.length {
                let font = storage.attribute(.font, at: marker.location, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: markdown.size)
                storage.addAttributes([
                    .foregroundColor: NSColor(markdown.checkbox),
                    .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                ], range: marker)
            }
        }
    }

    private func style(_ line: MarkdownSyntax.Line, in range: NSRange, storage: NSTextStorage) {
        let markdown = theme.markdown
        let size = CGFloat(markdown.size)
        var attributes = baseAttributes
        let paragraph = baseParagraph
        switch line.kind {
        case .heading(let level):
            let headingSize = level == 1 ? markdown.h1Size : level == 2 ? markdown.h2Size : level == 3 ? markdown.h3Size : markdown.size
            attributes[.font] = NSFont.slate(markdown.font, size: headingSize, weight: .bold)
            attributes[.foregroundColor] = NSColor(markdown.heading)
            paragraph.paragraphSpacingBefore = size * 0.6
        case .quote:
            attributes[.foregroundColor] = NSColor(markdown.quote)
            attributes[.font] = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
            paragraph.headIndent = size
            paragraph.firstLineHeadIndent = 0
        case .listItem, .task:
            paragraph.headIndent = size * 1.4
            paragraph.paragraphSpacing = size * 0.15
            if case .task(done: true) = line.kind {
                attributes[.foregroundColor] = NSColor(markdown.quote)
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        case .code, .fence:
            attributes[.font] = NSFont.slate(markdown.codeFont, size: markdown.size * 0.9)
            attributes[.backgroundColor] = NSColor(markdown.codeBackground)
            paragraph.paragraphSpacing = 0
        case .rule:
            attributes[.foregroundColor] = NSColor(markdown.quote)
        case .text, .blank:
            break
        }
        attributes[.paragraphStyle] = paragraph
        storage.setAttributes(attributes, range: range)

        let lineFont = attributes[.font] as? NSFont ?? bodyFont
        let faint = NSColor(markdown.text).withAlphaComponent(0.35)
        let graph = config.session?.links.graph
        for span in line.spans {
            let target = NSRange(location: range.location + span.range.location, length: span.range.length)
            guard NSMaxRange(target) <= storage.length else { continue }
            switch span.kind {
            case .marker:
                storage.addAttribute(.foregroundColor, value: faint, range: target)
            case .bold:
                storage.addAttribute(.font, value: NSFontManager.shared.convert(lineFont, toHaveTrait: .boldFontMask), range: target)
            case .italic:
                let current = storage.attribute(.font, at: target.location, effectiveRange: nil) as? NSFont ?? lineFont
                storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask), range: target)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: target)
            case .code:
                storage.addAttributes([
                    .font: NSFont.slate(markdown.codeFont, size: markdown.size * 0.9),
                    .backgroundColor: NSColor(markdown.codeBackground),
                ], range: target)
            case .link(let name):
                let resolved = graph?.resolve(name) != nil
                let color = NSColor(resolved ? markdown.wikiLink : markdown.brokenLink)
                var link: [NSAttributedString.Key: Any] = [
                    .foregroundColor: color,
                    .backgroundColor: color.withAlphaComponent(0.1),
                    .slateLinkTarget: name,
                ]
                if !resolved {
                    link[.underlineStyle] = NSUnderlineStyle.single.union(.patternDash).rawValue
                    link[.underlineColor] = color
                }
                storage.addAttributes(link, range: target)
                // Brackets stay dim inside the chip.
                storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.4), range: NSRange(location: target.location, length: 2))
                storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.4), range: NSRange(location: NSMaxRange(target) - 2, length: 2))
            }
        }
    }

    // MARK: - Lists

    /// Return at the end of a list item continues the list; on an empty
    /// item it ends the list.
    private func handleReturn() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0, let index = lineRanges.firstIndex(where: { $0.location <= selection.location && selection.location <= NSMaxRange($0) }) else { return false }
        let range = lineRanges[index]
        guard selection.location == NSMaxRange(range) else { return false }
        let line = (textView.string as NSString).substring(with: range)
        guard let match = line.firstMatch(of: /^(\s*)([-*+]|\d{1,9}[.)])(\s+)(\[[ xX]\]\s+)?/) else { return false }
        let content = line.dropFirst(match.0.count)
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            textView.insertText("", replacementRange: range)
            return true
        }
        var marker = String(match.2)
        if let number = Int(marker.dropLast()) { marker = "\(number + 1)\(marker.last!)" }
        let task = match.4 != nil ? "[ ] " : ""
        textView.insertText("\n" + match.1 + marker + match.3 + task, replacementRange: selection)
        return true
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        var editable = textView.string
        editable.makeContiguousUTF8()
        let full = config.hidesFrontmatter ? Frontmatter.replacingBody(of: config.document.text, with: editable) : editable
        syncedText = full
        if config.document.text != full { config.document.text = full }
        restyle(force: false)
        terms.textChanged()
        if !programmatic {
            config.session?.textDidChange(path: config.document.relativePath, text: full)
            completion.update(in: textView)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !programmatic, let textView else { return }
        completion.update(in: textView)
        let selected = textView.selectedRange()
        var words: String?
        if selected.length > 0, selected.length <= 200 {
            let text = (textView.string as NSString).substring(with: selected).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !text.contains(where: \.isNewline) { words = text }
        }
        if let session = config.session, words != nil || textView.window?.firstResponder === textView {
            DispatchQueue.main.async {
                if session.selectedText != words { session.selectedText = words }
            }
        }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if completion.handle(selector) { return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { return handleReturn() }
        return false
    }

    /// No spelling flags on links and code.
    func textView(
        _ view: NSTextView,
        didCheckTextIn range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:],
        results: [NSTextCheckingResult],
        orthography: NSOrthography,
        wordCount: Int
    ) -> [NSTextCheckingResult] {
        results.filter { result in
            result.resultType != .spelling || !protectedRanges.contains { NSIntersectionRange($0, result.range).length > 0 }
        }
    }
}

extension MarkdownEditorController {
    /// Ranges spell check skips: code blocks, fences, code spans and links.
    static func protectedRanges(lines: [MarkdownSyntax.Line], ranges: [NSRange]) -> [NSRange] {
        zip(lines, ranges).flatMap { line, range in
            (line.kind == .code || line.kind == .fence) ? [range] : line.spans.compactMap { span -> NSRange? in
                switch span.kind {
                case .code, .link: NSRange(location: range.location + span.range.location, length: span.range.length)
                default: nil
                }
            }
        }
    }

    /// The same, for a whole text (the Spelling tab).
    static func protectedRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var lines: [MarkdownSyntax.Line] = []
        var ranges: [NSRange] = []
        var location = 0
        var inFence = false
        while location <= ns.length {
            let end = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location)).location
            let lineEnd = end == NSNotFound ? ns.length : end
            let range = NSRange(location: location, length: lineEnd - location)
            let result = MarkdownSyntax.scan(line: ns.substring(with: range), inFence: inFence)
            lines.append(result.line)
            ranges.append(range)
            inFence = result.inFence
            if end == NSNotFound { break }
            location = lineEnd + 1
        }
        return protectedRanges(lines: lines, ranges: ranges)
    }
}
