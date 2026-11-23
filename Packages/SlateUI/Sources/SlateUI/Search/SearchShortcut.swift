import AppKit
import SwiftUI

/// A keyboard shortcut saved as text: `cmd+k`, `cmd+shift+space`, `ctrl+opt+f`.
struct SearchShortcut: Equatable {
    var key: KeyEquivalent
    var modifiers: EventModifiers
    /// The key as saved (`k`, `space`).
    var keyName: String

    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        var modifiers: EventModifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: return nil
            }
        }
        // A shortcut needs ⌘ or ⌃, or it would swallow typing.
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return nil }
        switch last {
        case "space": key = .space
        case "return": key = .return
        case "tab": key = .tab
        case "up": key = .upArrow
        case "down": key = .downArrow
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        default:
            guard last.count == 1, let char = last.first else { return nil }
            key = KeyEquivalent(char)
        }
        self.modifiers = modifiers
        keyName = last
    }

    /// From a key press in the recorder.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        let key: String
        switch event.keyCode {
        case 49: key = "space"
        case 36: key = "return"
        case 48: key = "tab"
        case 126: key = "up"
        case 125: key = "down"
        case 123: key = "left"
        case 124: key = "right"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return nil }
            key = chars
        }
        self.init((parts + [key]).joined(separator: "+"))
    }

    /// `cmd+shift+k`.
    var text: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [keyName]).joined(separator: "+")
    }

    /// `⇧⌘K`, as menus show it.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch keyName {
        case "space": text += "Space"
        case "return": text += "↩"
        case "tab": text += "⇥"
        case "up": text += "↑"
        case "down": text += "↓"
        case "left": text += "←"
        case "right": text += "→"
        default: text += keyName.uppercased()
        }
        return text
    }

    /// `text` written the one way Slate compares it (`ctrl+opt+shift+cmd+k`).
    static func normalized(_ text: String) -> String {
        SearchShortcut(text)?.text ?? ""
    }
}

/// Click, then press a shortcut. Esc cancels. Shortcuts already used
/// elsewhere in Slate (or by macOS) are refused with a note saying where.
struct ShortcutRecorder: View {
    @Binding var text: String
    var defaultText: String = SearchPreferences.defaultShortcut
    var actionID: String = Shortcuts.search
    @AppStorage(Shortcuts.overridesKey) private var overridesJSON = ""
    @AppStorage(SearchPreferences.shortcut) private var searchShortcut = SearchPreferences.defaultShortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack {
                if SearchShortcut.normalized(text) != SearchShortcut.normalized(defaultText) {
                    Button("Reset") { text = defaultText; problem = nil }
                        .controlSize(.small)
                        .help(defaultText.isEmpty ? "Back to no shortcut" : "Back to \(SearchShortcut(defaultText)?.display ?? defaultText)")
                }
                if !text.isEmpty, actionID != Shortcuts.search {
                    Button {
                        text = ""
                        problem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("No shortcut")
                }
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? "Press keys…" : (SearchShortcut(text)?.display ?? "None"))
                        .font(.body.monospaced())
                        .foregroundStyle(text.isEmpty && !recording ? .secondary : .primary)
                        .frame(minWidth: 110)
                }
                .help("Click, then press the keys you want (⌘ or ⌃ plus a key)")
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            guard let shortcut = SearchShortcut(event: event) else {
                problem = "Use ⌘ or ⌃ with a key."
                return nil
            }
            if let clash = Shortcuts.clash(shortcut.text, excluding: actionID,
                                           overrides: Shortcuts.overrides(overridesJSON), search: searchShortcut) {
                problem = "\(shortcut.display) is \(clash). Pick another, or change that one first."
                return nil
            }
            text = shortcut.text
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
