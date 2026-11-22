import AppKit
import CoreServices
import SlateCore
import SwiftUI

/// What an editor does with a dictionary word: the hover card, ⌘-click,
/// and the context-menu items.
@MainActor
struct DictionaryActions {
    var preview: (String) -> NSViewController?
    var follow: (String) -> Bool
    /// (word under the pointer, is it misspelled) → menu items.
    var menuItems: (String, Bool) -> [NSMenuItem]

    static let none = DictionaryActions(preview: { _ in nil }, follow: { _ in false }, menuItems: { _, _ in [] })

    /// Hooks a text view up to these actions and to a decorator's hits.
    @MainActor
    func install(in textView: SlateTextView, decorator: TermDecorator) {
        textView.termAt = { [weak decorator] index in decorator?.hit(at: index) }
        textView.previewForTerm = preview
        textView.followTerm = follow
        textView.dictionaryMenuItems = menuItems
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        handler()
    }
}

/// macOS's own dictionaries (Dictionary Services).
enum SystemDictionary {
    /// The definition of `word` from the user's active dictionaries, as plain text.
    static func definition(of word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = CFRange(location: 0, length: (trimmed as NSString).length)
        guard let definition = DCSCopyTextDefinition(nil, trimmed as CFString, range) else { return nil }
        return definition.takeRetainedValue() as String
    }

    /// Opens the word in the Dictionary app.
    static func lookUp(_ word: String) {
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        if let url = URL(string: "dict://" + encoded) { NSWorkspace.shared.open(url) }
    }
}

extension ProjectSession {
    /// The dictionary hooks for an editor. In the script a linked note
    /// opens in the margin, so you stay in the scene.
    func dictionaryActions(inScript: Bool) -> DictionaryActions {
        DictionaryActions(
            preview: { [weak self] word in self?.wordPreview(word) },
            follow: { [weak self] word in self?.followWord(word, inScript: inScript) ?? false },
            menuItems: { [weak self] word, misspelled in self?.dictionaryMenuItems(word: word, misspelled: misspelled) ?? [] }
        )
    }

    /// The hover card for a defined word, or the linked note's preview
    /// when the entry is only a link.
    func wordPreview(_ word: String) -> NSViewController? {
        guard let entry = dictionary.entry(for: word) else { return nil }
        if let target = entry.linkedNoteOnly, links.graph.resolve(target) != nil {
            return linkPreview(target)
        }
        let card = WordCard(entry: entry, isGlobal: dictionary.isGlobal(entry))
            .environment(\.openURL, OpenURLAction { [weak self] url in
                if let target = LinkURL.target(from: url) { self?.followLink(target) }
                return .handled
            })
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        let controller = NSHostingController(rootView: card)
        controller.sizingOptions = .preferredContentSize
        return controller
    }

    /// ⌘-click: the linked note when the entry is only a link, else the
    /// entry's page in the Dictionary (which links onward).
    @discardableResult
    func followWord(_ word: String, inScript: Bool) -> Bool {
        guard let entry = dictionary.entry(for: word) else { return false }
        if let target = entry.linkedNoteOnly, links.graph.resolve(target) != nil {
            return inScript ? peekLink(target) : followLink(target)
        }
        showInDictionary(entry)
        return true
    }

    func showInDictionary(_ entry: WordEntry) {
        area = .dictionary
        showingWordBookSource = false
        dictionaryQuery = ""
        dictionarySelection = DictionarySelection(entry, isGlobal: dictionary.isGlobal(entry))
    }

    func dictionaryMenuItems(word: String, misspelled: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if misspelled {
            items.append(ClosureMenuItem("Add to Project Dictionary") { [weak self] in self?.dictionary.learn(word, global: false) })
            items.append(ClosureMenuItem("Add to Every Project") { [weak self] in self?.dictionary.learn(word, global: true) })
        }
        if let entry = dictionary.entry(for: word), !entry.isSpellingOnly {
            items.append(ClosureMenuItem("Show “\(entry.word)” in Dictionary") { [weak self] in self?.showInDictionary(entry) })
        } else {
            items.append(ClosureMenuItem("Define “\(word)” in Dictionary…") { [weak self] in
                guard let self else { return }
                self.sheet = .wordEntry(self.dictionary.entry(for: word), word: word)
            })
        }
        return items
    }

    /// ⌃⌥⌘D: the Define panel for the selected words.
    func defineSelection() {
        inspectorTab = .define
        showingInspector = true
    }
}

extension ProjectSession {
    /// Spell check for the Markdown editors: notes, the draft and the word book.
    var noteSpelling: EditorSpelling {
        dictionary.spelling(for: .notes, characters: script.characterNames)
    }
}
