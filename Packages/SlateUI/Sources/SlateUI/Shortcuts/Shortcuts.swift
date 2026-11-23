import AppKit
import SlateCore
import SwiftUI

/// One menu command whose shortcut can be changed in Settings › Shortcuts.
public struct ShortcutAction: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let menu: String
    /// `cmd+shift+d`, or empty for no shortcut.
    public let defaultText: String
}

/// Every remappable shortcut, and the user's changes to them.
///
/// Changes are kept in `UserDefaults` › `shortcuts.overrides` as JSON
/// (`{"dictate": "ctrl+cmd+d", "save": ""}`; empty means none). Search keeps
/// its own key, `search.shortcut`, as before.
public enum Shortcuts {
    public static let overridesKey = "shortcuts.overrides"

    public static let actions: [ShortcutAction] = {
        var list: [ShortcutAction] = [
            .init(id: "newNote", title: "New Note / Add Word (New Project outside a project)", menu: "File", defaultText: "cmd+n"),
            .init(id: "newProject", title: "New Project", menu: "File", defaultText: "cmd+opt+n"),
            .init(id: "openFolder", title: "Open Folder…", menu: "File", defaultText: "cmd+o"),
            .init(id: "importVoiceNote", title: "Import Voice Note…", menu: "File", defaultText: ""),
            .init(id: "import", title: "Import…", menu: "File", defaultText: "cmd+shift+i"),
            .init(id: "projectLibrary", title: "Project Library", menu: "File", defaultText: "cmd+shift+l"),
            .init(id: "save", title: "Save", menu: "File", defaultText: "cmd+s"),
            .init(id: "printScript", title: "Print Script…", menu: "File", defaultText: "cmd+opt+p"),
            .init(id: search, title: "Search…", menu: "Edit", defaultText: SearchPreferences.defaultShortcut),
            .init(id: "searchText", title: "Search Text…", menu: "Edit", defaultText: "cmd+shift+f"),
            .init(id: "insertLink", title: "Insert Link", menu: "Edit", defaultText: "cmd+opt+k"),
            .init(id: "dictate", title: "Dictate", menu: "Edit", defaultText: "cmd+shift+d"),
            .init(id: "defineSelection", title: "Define Selection", menu: "Edit", defaultText: "ctrl+opt+cmd+d"),
            .init(id: "togglePageView", title: "Toggle Page View", menu: "Script", defaultText: "cmd+shift+\\"),
            .init(id: "publishPDF", title: "Publish › PDF", menu: "Script", defaultText: "cmd+shift+e"),
            .init(id: "nextFilm", title: "Next Film", menu: "Script", defaultText: "ctrl+cmd+]"),
            .init(id: "previousFilm", title: "Previous Film", menu: "Script", defaultText: "ctrl+cmd+["),
            .init(id: "saveSnapshot", title: "Save Snapshot…", menu: "Script", defaultText: "cmd+shift+s"),
            .init(id: "addTodo", title: "Add To-do…", menu: "Script", defaultText: "cmd+shift+t"),
            .init(id: "addMarginNote", title: "Add Margin Note…", menu: "Script", defaultText: "cmd+opt+t"),
            .init(id: "jumpToScene", title: "Jump to Scene…", menu: "Script", defaultText: "cmd+shift+o"),
            .init(id: "moveSceneUp", title: "Move Scene Up", menu: "Script", defaultText: "ctrl+cmd+up"),
            .init(id: "moveSceneDown", title: "Move Scene Down", menu: "Script", defaultText: "ctrl+cmd+down"),
            .init(id: "watchAnimatic", title: "Watch Animatic", menu: "Storyboard", defaultText: "cmd+opt+return"),
            .init(id: "newSketch", title: "New Sketch…", menu: "Storyboard", defaultText: "cmd+shift+k"),
        ]
        for area in ProjectArea.allCases {
            list.append(.init(id: "area." + area.rawValue, title: area.title, menu: "View", defaultText: "cmd+\(area.shortcutNumber)"))
        }
        list += [
            .init(id: "toggleInspector", title: "Toggle Sidebar", menu: "View", defaultText: "cmd+opt+0"),
            .init(id: "toggleMargin", title: "Show To-dos", menu: "View", defaultText: "cmd+shift+m"),
            .init(id: "focusMode", title: "Focus Mode", menu: "View", defaultText: "cmd+shift+return"),
            .init(id: "checkForUpdates", title: "Check for Updates…", menu: "Slate", defaultText: ""),
        ]
        return list
    }()

    public static let search = "search"

    /// Shortcuts that belong to macOS or to one view, shown but not changeable.
    public static let fixed: [(display: String, title: String, text: String)] = [
        ("⌘Z / ⇧⌘Z", "Undo / Redo", "cmd+z"), ("⌘X ⌘C ⌘V", "Cut, Copy, Paste", "cmd+c"), ("⌘A", "Select All", "cmd+a"),
        ("⌘F", "Find in the editor", "cmd+f"), ("⌘B ⌘I ⌘U", "Bold, Italic, Underline", "cmd+b"), ("⌘W", "Close Window", "cmd+w"),
        ("⌘,", "Settings", "cmd+,"), ("⌘Q", "Quit", "cmd+q"), ("⌃⌘F", "Full Screen", "ctrl+cmd+f"),
        ("⌘- ⌘= ⌘0", "Zoom out, in, to fit (canvas, map, timeline)", "cmd+0"),
        ("⇥ / ⇧⇥", "Script: cycle the line's element", ""), ("⌘K in a link field", "Insert Link while typing [[", ""),
    ]

    static let reserved: [String: String] = [
        "cmd+z": "Undo", "cmd+shift+z": "Redo", "cmd+c": "Copy", "cmd+v": "Paste", "cmd+x": "Cut", "cmd+a": "Select All",
        "cmd+f": "Find", "cmd+w": "Close", "cmd+q": "Quit", "cmd+,": "Settings", "cmd+0": "Fit", "cmd+=": "Zoom In",
        "cmd+-": "Zoom Out", "cmd+b": "Bold", "cmd+i": "Italic", "cmd+u": "Underline", "ctrl+cmd+f": "Full Screen",
        "cmd+h": "Hide Slate", "cmd+m": "Minimize",
    ]

    static func action(_ id: String) -> ShortcutAction? { actions.first { $0.id == id } }

    public static func overrides(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    static func encode(_ overrides: [String: String]) -> String {
        guard !overrides.isEmpty, let data = try? JSONEncoder().encode(overrides) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The shortcut text in effect for an action: the user's, else the default.
    public static func text(_ id: String, overrides: [String: String], search: String) -> String {
        if id == Self.search { return SearchShortcut.normalized(search) }
        return SearchShortcut.normalized(overrides[id] ?? action(id)?.defaultText ?? "")
    }

    /// The SwiftUI shortcut in effect, or nil for none.
    public static func shortcut(_ id: String, overrides: [String: String], search: String) -> KeyboardShortcut? {
        SearchShortcut(text(id, overrides: overrides, search: search)).map { KeyboardShortcut($0.key, modifiers: $0.modifiers) }
    }

    /// What else already uses `text`, if anything.
    static func clash(_ text: String, excluding id: String, overrides: [String: String], search: String) -> String? {
        let text = SearchShortcut.normalized(text)
        if let system = reserved.first(where: { SearchShortcut.normalized($0.key) == text })?.value { return "\(system) in macOS" }
        return actions.first { $0.id != id && Self.text($0.id, overrides: overrides, search: search) == text }?.title
    }
}

/// Reads the shortcuts in effect, for the menu bar.
@MainActor
struct ShortcutLookup {
    let overrides: [String: String]
    let search: String

    init(overridesJSON: String, search: String) {
        overrides = Shortcuts.overrides(overridesJSON)
        self.search = search
    }

    func callAsFunction(_ id: String) -> KeyboardShortcut? {
        Shortcuts.shortcut(id, overrides: overrides, search: search)
    }
}

/// Settings › Shortcuts: every menu shortcut, each one changeable.
struct ShortcutsSettings: View {
    @AppStorage(Shortcuts.overridesKey) private var overridesJSON = ""
    @AppStorage(SearchPreferences.shortcut) private var searchShortcut = SearchPreferences.defaultShortcut
    @State private var filter = ""

    var body: some View {
        let overrides = Shortcuts.overrides(overridesJSON)
        let menus = Shortcuts.actions.reduce(into: [String]()) { if !$0.contains($1.menu) { $0.append($1.menu) } }
        Form {
            Section {
                TextField("Filter", text: $filter, prompt: Text("Find a command"))
            } footer: {
                HStack {
                    Text("Click a shortcut, then press the keys you want (⌘ or ⌃ plus a key). Esc cancels.")
                    Spacer()
                    Button("Reset All") {
                        overridesJSON = ""
                        searchShortcut = SearchPreferences.defaultShortcut
                    }
                    .disabled(overrides.isEmpty && searchShortcut == SearchPreferences.defaultShortcut)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(menus, id: \.self) { menu in
                let rows = Shortcuts.actions.filter { $0.menu == menu && matches($0.title + " " + $0.menu) }
                if !rows.isEmpty {
                    Section(menu) {
                        ForEach(rows) { action in
                            LabeledContent(action.title) {
                                ShortcutRecorder(text: binding(action), defaultText: action.defaultText, actionID: action.id)
                            }
                        }
                    }
                }
            }
            let fixed = Shortcuts.fixed.filter { matches($0.title) }
            if !fixed.isEmpty {
                Section("Built in (not changeable)") {
                    ForEach(fixed, id: \.title) { item in
                        LabeledContent(item.title) {
                            Text(item.display).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func matches(_ text: String) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }

    private func binding(_ action: ShortcutAction) -> Binding<String> {
        if action.id == Shortcuts.search { return $searchShortcut }
        return Binding(
            get: { Shortcuts.text(action.id, overrides: Shortcuts.overrides(overridesJSON), search: searchShortcut) },
            set: { value in
                var overrides = Shortcuts.overrides(overridesJSON)
                let normalized = SearchShortcut.normalized(value)
                overrides[action.id] = normalized == SearchShortcut.normalized(action.defaultText) ? nil : normalized
                overridesJSON = Shortcuts.encode(overrides)
            }
        )
    }
}
