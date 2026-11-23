import AppKit
import Observation
import SlateCore

extension Notification.Name {
    /// Posted after Slate writes the global word book, so every open project re-reads it.
    static let slateGlobalWordsChanged = Notification.Name("SlateGlobalWordsChanged")
}

/// A project's dictionary: its word book (`dictionary/words.md`, edited
/// through its open document so autosave, outside edits and conflicts work
/// as for any file) plus the global book every project shares. Feeds spell
/// check and the defined-word underlines in every editor.
@MainActor
@Observable
final class DictionaryModel {
    let store: ProjectStore
    let globalURL: URL

    private(set) var entries: [WordEntry] = []
    private(set) var globalEntries: [WordEntry] = []
    /// Bumped whenever either book changes.
    private(set) var version = 0
    private(set) var matcher: TermMatcher = .empty
    private(set) var settings = SpellingPreferences.current
    var error: String?

    @ObservationIgnored private var lastProjectText: String?
    @ObservationIgnored private var lastGlobalText: String?
    @ObservationIgnored nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    init(store: ProjectStore, globalURL: URL = GlobalWords.defaultURL) {
        self.store = store
        self.globalURL = globalURL
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .slateGlobalWordsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGlobal() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGlobal() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = SpellingPreferences.current
                if current != self.settings { self.settings = current }
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Reading

    /// The project book's current text (the open document's, if open).
    var projectText: String { (try? store.readText(at: WordBook.path)) ?? "" }

    var bookExists: Bool {
        store.files[.dictionary]?.contains { $0.relativePath == WordBook.path } ?? false
    }

    /// Re-reads both books; cheap when nothing changed.
    func refresh() {
        // Keep the book open so outside edits arrive as observable document changes.
        if bookExists, store.documents[WordBook.path] == nil { _ = try? store.document(at: WordBook.path) }
        let project = projectText
        var changed = false
        if project != lastProjectText {
            lastProjectText = project
            entries = WordBook.parse(project)
            changed = true
        }
        if readGlobal() { changed = true }
        if changed { rebuild() }
    }

    func refreshGlobal() {
        if readGlobal() { rebuild() }
    }

    private func readGlobal() -> Bool {
        let text = (try? CoordinatedFileIO.readText(globalURL)) ?? ""
        guard text != lastGlobalText else { return false }
        lastGlobalText = text
        globalEntries = WordBook.parse(text)
        return true
    }

    private func rebuild() {
        matcher = TermMatcher(entries: entries + globalEntries)
        version += 1
    }

    func ignoredWords(characters: [String]) -> [String] {
        SpellService.ignoredWords(books: [entries, globalEntries], characters: characters)
    }

    func spelling(for area: EditorSpelling.Area, characters: [String]) -> EditorSpelling {
        EditorSpelling(
            ignoredWords: ignoredWords(characters: characters),
            matcher: matcher,
            matcherVersion: version,
            grammar: settings.grammar[area] ?? false,
            autocorrect: settings.autocorrect,
            language: settings.language,
            checking: settings.check[area] ?? true
        )
    }

    /// The entry for a word or form: the project's first, then the global book's.
    func entry(for word: String) -> WordEntry? {
        WordBook.entry(for: word, in: entries) ?? WordBook.entry(for: word, in: globalEntries)
    }

    func isGlobal(_ entry: WordEntry) -> Bool {
        !entries.contains(entry) && globalEntries.contains(entry)
    }

    // MARK: - Editing

    /// Adds a word to the project or global book. Spelling-only words
    /// already in either book aren't added again.
    func learn(_ word: String, global: Bool) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let book = global ? globalEntries : entries
        guard WordBook.entry(for: word, in: book) == nil else { return }
        add(WordEntry(word: word), global: global)
    }

    func add(_ entry: WordEntry, global: Bool = false) {
        edit(global: global) { WordBook.adding(entry, to: $0) }
    }

    func update(_ entry: WordEntry, to updated: WordEntry) {
        edit(global: isGlobal(entry)) { WordBook.replacing(entry, with: updated, in: $0) }
    }

    func delete(_ entry: WordEntry) {
        edit(global: isGlobal(entry)) { WordBook.removing(entry, in: $0) }
    }

    /// nil from `change` means the entry moved since it was shown.
    private func edit(global: Bool, _ change: (String) -> String?) {
        if global {
            do {
                let text = (try? CoordinatedFileIO.readText(globalURL)) ?? ""
                guard let updated = change(text) else { return stale() }
                try FileManager.default.createDirectory(at: globalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try CoordinatedFileIO.writeText(updated, to: globalURL)
                error = nil
                NotificationCenter.default.post(name: .slateGlobalWordsChanged, object: nil)
            } catch {
                self.error = error.localizedDescription
            }
            refreshGlobal()
            return
        }
        do {
            let document: TextDocument
            if let open = store.documents[WordBook.path] {
                document = open
            } else if bookExists {
                document = try store.document(at: WordBook.path)
            } else {
                document = try store.createTextFile(at: WordBook.path, contents: WordBook.starter)
            }
            guard let updated = change(document.text) else { return stale() }
            error = nil
            if updated != document.text { document.text = updated }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    private func stale() {
        error = "That word changed in the file since it was shown. The list has been refreshed."
        refresh()
    }
}

/// Which word the Dictionary area shows: the word (folded, so it survives
/// edits that move its line) and which book it's in.
struct DictionarySelection: Hashable {
    let key: String
    let isGlobal: Bool

    init(_ entry: WordEntry, isGlobal: Bool) {
        key = entry.word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        self.isGlobal = isGlobal
    }

    func matches(_ entry: WordEntry) -> Bool {
        entry.word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) == key
    }
}
