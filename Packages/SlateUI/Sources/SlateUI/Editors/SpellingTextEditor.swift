import AppKit
import SwiftUI

/// A plain multi-line text field backed by `NSTextView`, so the per-area
/// spelling settings and the project's word list apply (SwiftUI's
/// `TextEditor` only uses the system's).
struct SpellingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var spelling: EditorSpelling
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var focusOnAppear = false
    var onEscape: (() -> Void)?
    var onEndEditing: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.string = text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setAccessibilityLabel("Text")
        context.coordinator.decorator = TermDecorator(textView: textView)
        context.coordinator.decorator?.apply(spelling, color: .systemPurple)
        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        context.coordinator.decorator?.apply(spelling, color: .systemPurple)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SpellingTextEditor
        var decorator: TermDecorator?

        init(_ parent: SpellingTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            decorator?.textChanged()
        }

        func textDidEndEditing(_ notification: Notification) { parent.onEndEditing?() }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)), let onEscape = parent.onEscape {
                onEscape()
                return true
            }
            return false
        }
    }
}
