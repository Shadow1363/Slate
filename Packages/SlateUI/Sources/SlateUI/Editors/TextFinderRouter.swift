import AppKit

/// Edit › Find: sends the native find-bar actions to the text editor in the
/// key window. If the keyboard is elsewhere (a sidebar list), the visible
/// editor takes it first, so ⌘F in Script always finds in the script.
@MainActor
enum TextFinderRouter {
    /// Runs `action` in the key window's editor. False when there's no editor to find in.
    @discardableResult
    static func perform(_ action: NSTextFinder.Action, in window: NSWindow? = NSApp.keyWindow) -> Bool {
        guard let window, let textView = editor(in: window) else { return false }
        if window.firstResponder !== textView { window.makeFirstResponder(textView) }
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
        return true
    }

    /// The focused editor, else the first visible one that uses the find bar.
    static func editor(in window: NSWindow) -> NSTextView? {
        if let focused = window.firstResponder as? NSTextView, !focused.isFieldEditor, focused.usesFindBar {
            return focused
        }
        guard let root = window.contentView else { return nil }
        return firstFindable(in: root)
    }

    private static func firstFindable(in view: NSView) -> NSTextView? {
        if view.isHiddenOrHasHiddenAncestor { return nil }
        if let textView = view as? NSTextView, textView.usesFindBar, !textView.isFieldEditor,
           !textView.visibleRect.isEmpty {
            return textView
        }
        for subview in view.subviews {
            if let found = firstFindable(in: subview) { return found }
        }
        return nil
    }
}
