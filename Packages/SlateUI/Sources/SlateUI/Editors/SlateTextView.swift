import AppKit
import SlateCore

extension NSAttributedString.Key {
    /// The target of a `[[link]]`, set by the editors' stylers.
    static let slateLinkTarget = NSAttributedString.Key("SlateLinkTarget")
}

/// The text view behind Slate's editors (TextKit 2). ⌘-click on a styled
/// `[[link]]` or a defined dictionary word follows it; the cursor becomes a
/// pointing hand over them while ⌘ is held. Hovering shows a preview, and
/// the context menu adds the dictionary's spelling items.
final class SlateTextView: NSTextView {
    /// Called with a link's target on ⌘-click. Return true if handled.
    var followLink: ((String) -> Bool)?
    /// ⌘K: insert a link.
    var insertLinkAction: (() -> Void)?
    /// A preview of a link's target, shown after hovering over the link.
    var previewForLink: ((String) -> NSViewController?)?
    /// The defined dictionary word at a character index (from the editor's `TermDecorator`).
    var termAt: ((Int) -> TermMatcher.Hit?)?
    /// The definition card for a dictionary word.
    var previewForTerm: ((String) -> NSViewController?)?
    /// ⌘-click on a dictionary word. Return true if handled.
    var followTerm: ((String) -> Bool)?
    /// Context-menu items for the word under the pointer: (word, misspelled).
    var dictionaryMenuItems: ((String, Bool) -> [NSMenuItem])?

    private enum HoverItem: Equatable {
        case link(String)
        case term(String, NSRange)
    }

    private var hoverTarget: HoverItem?
    private var hoverWork: DispatchWorkItem?
    private var previewPopover: NSPopover?
    private var hoverArea: NSTrackingArea?

    /// A scroll view holding a new, vertically growing text view.
    static func scrollable() -> (NSScrollView, SlateTextView) {
        let textView = SlateTextView(usingTextLayoutManager: true)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    /// The link target at a point in the view, if any.
    func linkTarget(at point: NSPoint) -> String? {
        let index = characterIndexForInsertion(at: point)
        guard let storage = textStorage, storage.length > 0 else { return nil }
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            if let target = storage.attribute(.slateLinkTarget, at: candidate, effectiveRange: nil) as? String {
                return target
            }
        }
        return nil
    }

    /// The link or dictionary word at a point, links first.
    private func hoverItem(at point: NSPoint) -> HoverItem? {
        if let target = linkTarget(at: point) { return .link(target) }
        guard let termAt else { return nil }
        let index = characterIndexForInsertion(at: point)
        // Only when the pointer is over the glyphs, not past the line's end.
        guard let hit = termAt(index) ?? termAt(index - 1) else { return nil }
        var actual = NSRange()
        guard let window else { return nil }
        let screen = firstRect(forCharacterRange: hit.range, actualRange: &actual)
        let local = convert(window.convertFromScreen(screen), from: nil)
        return local.insetBy(dx: -2, dy: -2).contains(point) ? .term(hit.word, hit.range) : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch hoverItem(at: convert(event.locationInWindow, from: nil)) {
            case .link(let target) where followLink?(target) == true: return
            case .term(let word, _) where followTerm?(word) == true: return
            default: break
            }
        }
        super.mouseDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let target = hoverItem(at: point)
        updateHover(target, at: point)
        if event.modifierFlags.contains(.command), target != nil {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHover(nil, at: .zero)
    }

    override func keyDown(with event: NSEvent) {
        closePreview()
        super.keyDown(with: event)
    }

    /// Shows the preview after the pointer rests on a link or word for half a second.
    private func updateHover(_ target: HoverItem?, at point: NSPoint) {
        guard target != hoverTarget else { return }
        hoverTarget = target
        hoverWork?.cancel()
        closePreview()
        guard let target else { return }
        let index = characterIndexForInsertion(at: point)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showPreview(for: target, near: index) }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func showPreview(for target: HoverItem, near index: Int) {
        guard hoverTarget == target, let window, let storage = textStorage, storage.length > 0 else { return }
        var range = NSRange()
        let controller: NSViewController?
        switch target {
        case .link(let name):
            let at = min(max(index, 0), storage.length - 1)
            guard storage.attribute(.slateLinkTarget, at: at, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil
                || storage.attribute(.slateLinkTarget, at: max(at - 1, 0), longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil
            else { return }
            controller = previewForLink?(name)
        case .term(let word, let wordRange):
            guard NSMaxRange(wordRange) <= storage.length else { return }
            range = wordRange
            controller = previewForTerm?(word)
        }
        guard let controller else { return }
        var actual = NSRange()
        let screenRect = firstRect(forCharacterRange: range, actualRange: &actual)
        let local = convert(window.convertFromScreen(screenRect), from: nil)
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentViewController = controller
        popover.show(relativeTo: local, of: self, preferredEdge: .maxY)
        previewPopover = popover
    }

    func closePreview() {
        previewPopover?.performClose(nil)
        previewPopover = nil
    }

    // MARK: - Context menu

    /// The word under a point and its range.
    func word(at point: NSPoint) -> (String, NSRange)? {
        let index = characterIndexForInsertion(at: point)
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        let range = selectionRange(forProposedRange: NSRange(location: min(index, length - 1), length: 0), granularity: .selectByWord)
        guard range.length > 0, NSMaxRange(range) <= length else { return nil }
        let word = (string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return word.isEmpty || !word.contains(where: \.isLetter) ? nil : (word, range)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, let dictionaryMenuItems,
              let (word, _) = word(at: convert(event.locationInWindow, from: nil)) else { return menu }
        let checker = NSSpellChecker.shared
        let misspelled = checker.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false,
                                               inSpellDocumentWithTag: spellCheckerDocumentTag, wordCount: nil).location != NSNotFound
        let items = dictionaryMenuItems(word, misspelled)
        guard !items.isEmpty else { return menu }
        // Slate's own "learn" items replace the system's, which would teach every app.
        var insertAt = 0
        if let learn = menu.items.firstIndex(where: { $0.action == NSSelectorFromString("learnSpelling:") }) {
            menu.removeItem(at: learn)
            insertAt = learn
        } else if let ignore = menu.items.firstIndex(where: { $0.action == NSSelectorFromString("ignoreSpelling:") }) {
            insertAt = ignore + 1
        }
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: insertAt + offset) }
        if insertAt == 0 { menu.insertItem(.separator(), at: items.count) }
        return menu
    }

    /// Edit › Insert Link (⌘K), sent down the responder chain.
    @objc func insertWikiLink(_ sender: Any?) {
        insertLinkAction?()
    }
}
