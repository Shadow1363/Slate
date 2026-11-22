import AppKit
import SlateCore
import SwiftUI

/// A plain-text `NSTextView` (TextKit 2) with spell check on and the
/// "smart" substitutions off. The script and Markdown editors build on it.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var theme: ResolvedTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        // Off by default for screenwriting (SPEC: Spell check › Settings).
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.string = text
        context.coordinator.apply(theme, to: textView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.replaceAll(in: textView, with: text)
        }
        if context.coordinator.appliedTheme != theme {
            context.coordinator.apply(theme, to: textView, scrollView: scrollView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        var appliedTheme: ResolvedTheme?
        private var isReplacing = false

        init(_ parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isReplacing, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        /// Swaps in text that changed outside the editor (a reload from disk)
        /// as one undoable edit, keeping the selection where it can.
        func replaceAll(in textView: NSTextView, with newText: String) {
            let selection = textView.selectedRange()
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            isReplacing = true
            defer { isReplacing = false }
            if textView.shouldChangeText(in: fullRange, replacementString: newText) {
                textView.textStorage?.replaceCharacters(in: fullRange, with: newText)
                textView.didChangeText()
            } else {
                textView.string = newText
            }
            let length = (newText as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            if let appliedTheme { applyTextAttributes(appliedTheme, to: textView) }
        }

        func apply(_ theme: ResolvedTheme, to textView: NSTextView, scrollView: NSScrollView) {
            appliedTheme = theme
            let background = NSColor(theme.editor.background)
            scrollView.backgroundColor = background
            textView.backgroundColor = background
            textView.insertionPointColor = NSColor(theme.editor.caret)
            textView.selectedTextAttributes = [.backgroundColor: NSColor(theme.editor.selection)]
            applyTextAttributes(theme, to: textView)
        }

        private func applyTextAttributes(_ theme: ResolvedTheme, to textView: NSTextView) {
            let font = NSFont.slate(theme.editor.font, size: theme.editor.size)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = theme.editor.lineSpacing
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(theme.editor.text),
                .paragraphStyle: paragraph,
            ]
            textView.typingAttributes = attributes
            textView.defaultParagraphStyle = paragraph
            if let storage = textView.textStorage, storage.length > 0 {
                storage.beginEditing()
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
                storage.endEditing()
            }
        }
    }
}
