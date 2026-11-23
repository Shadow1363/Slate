import AppKit
import SlateVoice
import SwiftUI

/// Edit › Dictate (⇧⌘D): speak into whichever Slate editor has the cursor.
/// A small panel by the cursor shows the level and, with Apple, the words as
/// they're heard. Pressing the shortcut again (or Insert) puts the text in.
@MainActor
final class DictationController {
    static let shared = DictationController()

    private var dictation: Dictation?
    private weak var textView: NSTextView?
    private var popover: NSPopover?

    var isActive: Bool { dictation != nil }

    func toggle(in textView: NSTextView) {
        if let dictation {
            if dictation.phase == .listening {
                finish()
            } else if case .failed = dictation.phase {
                close()
            }
            return
        }
        start(in: textView)
    }

    private func start(in textView: NSTextView) {
        let dictation = Dictation(settings: .current())
        self.dictation = dictation
        self.textView = textView
        let hud = DictationHUD(dictation: dictation, insert: { [weak self] in self?.finish() },
                               cancel: { [weak self] in self?.close() })
        let controller = NSHostingController(rootView: hud)
        controller.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        var actual = NSRange()
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: &actual)
        if let window = textView.window {
            var local = textView.convert(window.convertFromScreen(caret), from: nil)
            if local.width < 1 { local.size.width = 1 }
            popover.show(relativeTo: local, of: textView, preferredEdge: .maxY)
        }
        self.popover = popover
        Task { await dictation.start() }
    }

    private func finish() {
        guard let dictation, dictation.phase == .listening else { return }
        Task {
            let text = await dictation.finish()
            guard self.dictation === dictation else { return }
            if let text, let textView {
                insert(text, into: textView)
                close()
            }
            // On failure the panel stays open showing why, until Close.
        }
    }

    private func close() {
        dictation?.cancel()
        dictation = nil
        popover?.performClose(nil)
        popover = nil
        textView?.window?.makeFirstResponder(textView)
    }

    private func insert(_ text: String, into textView: NSTextView) {
        let range = textView.selectedRange()
        let string = textView.string as NSString
        let start = max(0, range.location - 3)
        let preceding = Substring(string.substring(with: NSRange(location: start, length: range.location - start)))
        let end = NSMaxRange(range)
        let following = end < string.length ? string.substring(with: NSRange(location: end, length: 1)).first : nil
        let insertion = TranscriptText.insertion(text, preceding: preceding, following: following)
        // Goes through the editor's delegate and undo, like typing.
        textView.insertText(insertion, replacementRange: range)
    }
}

private struct DictationHUD: View {
    let dictation: Dictation
    let insert: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch dictation.phase {
            case .starting:
                Label("Starting the microphone…", systemImage: "mic")
            case .listening:
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    LevelMeter(level: dictation.level)
                    Text(Duration.seconds(dictation.elapsed).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !dictation.partial.isEmpty {
                    Text(dictation.partial)
                        .font(.callout)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(dictation.settings.engine == .apple ? "Listening…" : "Listening. The text appears when you stop.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .transcribing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(dictation.settings.engine == .openAI ? "Sending to OpenAI…" : "Transcribing…")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(dictation.settings.engine.title).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if case .failed = dictation.phase {
                    Button("Voice Settings…") {
                        cancel()
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    Button("Close", action: cancel).keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    Button("Insert", action: insert)
                        .keyboardShortcut(.defaultAction)
                        .disabled(dictation.phase != .listening)
                        .help("Stop and insert the text (⇧⌘D)")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green.gradient)
                    .frame(width: max(4, proxy.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
