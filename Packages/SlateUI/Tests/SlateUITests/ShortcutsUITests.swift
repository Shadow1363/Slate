import Foundation
import SwiftUI
import Testing
@testable import SlateUI

@Suite("Shortcuts")
@MainActor
struct ShortcutsUITests {
    @Test func everyDefaultParsesAndIsUnique() {
        var seen: [String: String] = [:]
        for action in Shortcuts.actions where !action.defaultText.isEmpty {
            let text = SearchShortcut.normalized(action.defaultText)
            #expect(!text.isEmpty, "\(action.id) default doesn't parse")
            #expect(seen[text] == nil, "\(action.id) and \(seen[text] ?? "") share \(text)")
            seen[text] = action.id
            #expect(Shortcuts.reserved.keys.map(SearchShortcut.normalized).contains(text) == false)
        }
        #expect(Set(Shortcuts.actions.map(\.id)).count == Shortcuts.actions.count)
    }

    @Test func overridesReplaceDefaults() {
        let overrides = Shortcuts.overrides(#"{"dictate":"ctrl+cmd+d","save":""}"#)
        #expect(Shortcuts.text("dictate", overrides: overrides, search: "cmd+k") == "ctrl+cmd+d")
        #expect(Shortcuts.shortcut("save", overrides: overrides, search: "cmd+k") == nil)
        #expect(Shortcuts.text("openFolder", overrides: overrides, search: "cmd+k") == "cmd+o")
        #expect(Shortcuts.text(Shortcuts.search, overrides: overrides, search: "cmd+shift+space") == "shift+cmd+space")
        #expect(Shortcuts.overrides("not json").isEmpty)
        #expect(Shortcuts.encode([:]) == "")
    }

    @Test func clashesNameTheOtherCommand() {
        #expect(Shortcuts.clash("shift+cmd+d", excluding: "save", overrides: [:], search: "cmd+k") == "Dictate")
        #expect(Shortcuts.clash("cmd+shift+d", excluding: "dictate", overrides: [:], search: "cmd+k") == nil)
        #expect(Shortcuts.clash("cmd+z", excluding: "dictate", overrides: [:], search: "cmd+k") == "Undo in macOS")
        // A freed shortcut can be reused.
        #expect(Shortcuts.clash("cmd+s", excluding: "dictate", overrides: ["save": ""], search: "cmd+k") == nil)
    }

    @Test func arrowsRoundTrip() throws {
        let up = try #require(SearchShortcut("ctrl+cmd+up"))
        #expect(up.key == .upArrow)
        #expect(up.display == "⌃⌘↑")
        #expect(up.text == "ctrl+cmd+up")
    }
}
