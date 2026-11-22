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
        if event.modifierFlags.contains(.command), linkTarget(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    /// Edit › Insert Link (⌘K), sent down the responder chain.
    @objc func insertWikiLink(_ sender: Any?) {
        insertLinkAction?()
    }
}
