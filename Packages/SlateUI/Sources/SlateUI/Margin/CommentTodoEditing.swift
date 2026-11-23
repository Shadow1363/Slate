import AppKit
import SlateCore

/// `TODO:` comments inside an editor: the right-click item that ticks one,
/// and ⇧⌘T in a note, which writes a new one at the caret.
@MainActor
enum CommentTodoEditing {
    /// The to-do comment containing a character, if any. Script editors only
    /// count `/* */`.
    static func todo(at index: Int, in textView: NSTextView, script: Bool) -> CommentTodo? {
        let path = script ? "script/editor.md" : "universe/editor.md"
        return CommentTodos.scan(text: textView.string, path: path).first {
            NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index
        }
    }

    static func menuItems(at index: Int, in textView: NSTextView, script: Bool) -> [NSMenuItem] {
        guard let todo = todo(at: index, in: textView, script: script) else { return [] }
        return [ClosureMenuItem(todo.done ? "Mark To-do Not Done" : "Mark To-do Done") { [weak textView] in
            guard let textView else { return }
            toggle(todo, in: textView)
        }]
    }

    /// Swaps `TODO`/`DONE` as one undoable edit, through the editor's normal change path.
    static func toggle(_ todo: CommentTodo, in textView: NSTextView) {
        let text = textView.string as NSString
        guard NSMaxRange(todo.range) <= text.length, text.substring(with: todo.range) == todo.source else { return }
        textView.insertText(CommentTodos.toggledSource(todo), replacementRange: todo.range)
    }

    /// Writes `%% TODO:  %%` at the caret, with the caret ready for the words.
    static func insertNew(in textView: NSTextView) {
        let comment = CommentTodos.newNoteComment
        let selection = textView.selectedRange()
        let at = NSRange(location: NSMaxRange(selection), length: 0)
        let text = textView.string as NSString
        let before = at.location > 0 ? text.substring(with: NSRange(location: at.location - 1, length: 1)) : "\n"
        let spaced = (before == "\n" || before == " " ? "" : " ") + comment.text
        textView.insertText(spaced, replacementRange: at)
        textView.setSelectedRange(NSRange(location: at.location + spaced.count - comment.text.count + comment.caret, length: 0))
    }
}
