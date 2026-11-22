import AppKit
import SlateCore

extension NSAttributedString.Key {
    /// The target of a `[[link]]`, set by the editors' stylers.
    static let slateLinkTarget = NSAttributedString.Key("SlateLinkTarget")
}

/// The text view behind Slate's editors (TextKit 2). ⌘-click on a styled
/// `[[link]]` follows it; the cursor becomes a pointing hand over links
/// while ⌘ is held.
final class SlateTextView: NSTextView {
    /// Called with a link's target on ⌘-click. Return true if handled.
    var followLink: ((String) -> Bool)?
    /// ⌘K: insert a link.
    var insertLinkAction: (() -> Void)?
    /// A preview of a link's target, shown after hovering over the link.
    var previewForLink: ((String) -> NSViewController?)?

    private var hoverTarget: String?
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

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let target = linkTarget(at: convert(event.locationInWindow, from: nil)),
           followLink?(target) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let target = linkTarget(at: point)
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

    /// Shows the preview after the pointer rests on a link for half a second.
    private func updateHover(_ target: String?, at point: NSPoint) {
        guard target != hoverTarget else { return }
        hoverTarget = target
        hoverWork?.cancel()
        closePreview()
        guard let target, previewForLink != nil else { return }
        let index = characterIndexForInsertion(at: point)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showPreview(for: target, near: index) }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func showPreview(for target: String, near index: Int) {
        guard hoverTarget == target, let window, let storage = textStorage, storage.length > 0,
              let controller = previewForLink?(target) else { return }
        var range = NSRange()
        let at = min(max(index, 0), storage.length - 1)
        guard storage.attribute(.slateLinkTarget, at: at, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil
            || storage.attribute(.slateLinkTarget, at: max(at - 1, 0), longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil
        else { return }
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

    /// Edit › Insert Link (⌘K), sent down the responder chain.
    @objc func insertWikiLink(_ sender: Any?) {
        insertLinkAction?()
    }
}
