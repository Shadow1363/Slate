import AppKit
import Observation
import SlateCore
import SwiftUI

/// `[[` autocomplete for any Slate text view.
///
/// After each edit or caret move the editor calls `update(in:)`. While the
/// caret sits in an unfinished `[[name`, matching notes show in a small
/// panel under the caret; ↑/↓ choose, Return or Tab insert, Esc dismisses.
@MainActor
@Observable
final class LinkCompletion {
    private(set) var items: [LinkGraph.Completion] = []
    var selection = 0
    /// The typed part after `[[` (UTF-16 range in the text).
    private(set) var queryRange: NSRange?

    @ObservationIgnored var graph: () -> LinkGraph = { .empty }
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var textView: NSTextView?
    /// Set by Esc; cleared when the caret leaves this link.
    @ObservationIgnored private var dismissedAt: Int?

    var isActive: Bool { queryRange != nil && !items.isEmpty }

    /// The unfinished link the caret is in: the range after `[[` up to the
    /// caret, if there's no `]`, `[`, `|` or line break in between.
    static func openLinkQuery(in text: NSString, caret: Int) -> NSRange? {
        var index = caret
        while index > 0 {
            let char = text.character(at: index - 1)
            switch char {
            case 0x0A, 0x0D, 0x5D, 0x7C: // \n \r ] |
                return nil
            case 0x5B: // [
                guard index >= 2, text.character(at: index - 2) == 0x5B else { return nil }
                return NSRange(location: index, length: caret - index)
            default:
                index -= 1
            }
        }
        return nil
    }

    func update(in textView: NSTextView) {
        self.textView = textView
        let selection = textView.selectedRange()
        let text = textView.string as NSString
        guard selection.length == 0, !textView.hasMarkedText(),
              let range = Self.openLinkQuery(in: text, caret: selection.location) else {
            dismissedAt = nil
            hide()
            return
        }
        if dismissedAt == range.location {
            hide(keepingState: false)
            return
        }
        dismissedAt = nil
        let query = text.substring(with: range)
        let found = graph().completions(prefix: query, limit: 8)
        queryRange = range
        if found.map(\.id) != items.map(\.id) { self.selection = 0 }
        items = found
        if items.isEmpty { hidePanel() } else { showPanel(in: textView) }
    }

    /// Key handling while the list shows. Returns true if the key was used.
    func handle(_ selector: Selector) -> Bool {
        guard isActive, let textView else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            selection = min(selection + 1, items.count - 1)
        case #selector(NSResponder.moveUp(_:)):
            selection = max(selection - 1, 0)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            accept(in: textView)
        case #selector(NSResponder.cancelOperation(_:)):
            dismissedAt = queryRange?.location
            hide()
        default:
            return false
        }
        return true
    }

    /// Replaces the typed part with the chosen name and closes the link.
    func accept(in textView: NSTextView, index: Int? = nil) {
        guard let queryRange, items.indices.contains(index ?? selection) else { return }
        let item = items[index ?? selection]
        let text = textView.string as NSString
        var range = queryRange
        // Swallow a `]]` that's already after the caret.
        let after = NSMaxRange(range)
        if after + 2 <= text.length, text.substring(with: NSRange(location: after, length: 2)) == "]]" {
            range.length += 2
        }
        hide()
        let insert = item.text + "]]"
        textView.insertText(insert, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + (insert as NSString).length, length: 0))
    }

    /// ⌘K: inserts `[[]]` (or wraps the selection) and opens the list.
    func insertLink(in textView: NSTextView) {
        let selection = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: selection)
        if selected.isEmpty {
            textView.insertText("[[]]", replacementRange: selection)
            textView.setSelectedRange(NSRange(location: selection.location + 2, length: 0))
        } else {
            textView.insertText("[[\(selected)]]", replacementRange: selection)
        }
        update(in: textView)
    }

    func hide(keepingState: Bool = false) {
        if !keepingState {
            queryRange = nil
            items = []
            selection = 0
        }
        hidePanel()
    }

    // MARK: - Panel

    private func showPanel(in textView: NSTextView) {
        guard let window = textView.window, let queryRange else { return }
        let panel = panel ?? makePanel()
        var actual = NSRange()
        let caretRect = textView.firstRect(forCharacterRange: NSRange(location: queryRange.location, length: 0), actualRange: &actual)
        let size = NSSize(width: 300, height: CGFloat(items.count) * 26 + 10)
        panel.setFrame(NSRect(x: caretRect.minX - 12, y: caretRect.minY - size.height - 4, width: size.width, height: size.height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: LinkCompletionList(model: self) { [weak self] index in
            guard let self, let textView = self.textView else { return }
            self.accept(in: textView, index: index)
        })
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

private struct LinkCompletionList: View {
    let model: LinkCompletion
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: item.note.type))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(item.text).lineLimit(1)
                    if item.isAlias {
                        Text("→ \(item.note.name)").foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(index == model.selection ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .accessibilityLabel("Link suggestions")
    }
}

/// SF Symbol for a note type.
func icon(for type: String?) -> String {
    switch type {
    case "character": "person"
    case "location": "mappin.and.ellipse"
    case "rule": "gearshape.2"
    case "faction": "person.3"
    case "item": "key"
    case "event": "calendar"
    case "term": "character.book.closed"
    default: "doc.text"
    }
}
