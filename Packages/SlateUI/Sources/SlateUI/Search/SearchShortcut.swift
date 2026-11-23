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
        default: text += keyName.uppercased()
        }
        return text
    }

    /// Slate's own shortcuts this one would take over, if any.
    var clash: String? {
        Self.taken[text]
    }

    static let taken: [String: String] = [
        "cmd+n": "New Note", "cmd+o": "Open Folder", "cmd+s": "Save", "cmd+shift+s": "Save Snapshot", "cmd+opt+k": "Insert Link",
        "cmd+shift+k": "New Sketch", "cmd+shift+f": "Search Text", "cmd+shift+i": "Import", "cmd+shift+l": "Project Library",
        "cmd+shift+t": "Add To-do", "cmd+opt+t": "Add Margin Note", "cmd+shift+m": "Toggle Margin", "cmd+shift+o": "Jump to Scene",
        "cmd+shift+e": "Publish PDF", "cmd+opt+p": "Print Script", "cmd+1": "Universe", "cmd+2": "Script", "cmd+3": "Storyboard",
        "cmd+4": "Dictionary", "cmd+z": "Undo", "cmd+shift+z": "Redo", "cmd+c": "Copy", "cmd+v": "Paste", "cmd+x": "Cut",
        "cmd+a": "Select All", "cmd+f": "Find", "cmd+w": "Close", "cmd+q": "Quit", "cmd+comma": "Settings", "cmd+,": "Settings",
        "cmd+opt+0": "Inspector", "cmd+0": "Fit", "cmd+=": "Zoom In", "cmd+-": "Zoom Out", "cmd+b": "Bold", "cmd+i": "Italic",
        "cmd+u": "Underline", "cmd+shift+\\": "Page View", "ctrl+cmd+f": "Full Screen", "cmd+shift+return": "Focus Mode",
        "cmd+opt+return": "Watch Animatic", "ctrl+cmd+]": "Next Film", "ctrl+cmd+[": "Previous Film",
    ]
}

/// Click, then press a shortcut. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var text: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        HStack {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press a shortcut…" : (SearchShortcut(text)?.display ?? text))
                    .font(.body.monospaced())
                    .frame(minWidth: 140)
            }
            .help("Click, then press the keys you want (⌘ or ⌃ plus a key)")
            if text != SearchPreferences.defaultShortcut {
                Button("Reset") { text = SearchPreferences.defaultShortcut; problem = nil }
            }
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
        }
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
            if let clash = shortcut.clash {
                problem = "\(shortcut.display) is \(clash) in Slate. Pick another."
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
