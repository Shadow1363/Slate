import Foundation
import Observation
import SlateCore

/// Where the editor should put the caret and scroll to.
struct RevealRequest: Equatable {
    let file: String
    let location: Int
    let focus: Bool
    let token = UUID()
}

/// The caret as the editor last reported it.
struct ScriptCaret: Equatable {
    var file: String
    var location: Int
    var kind: ScriptElementKind
    var sceneIndex: Int?
}

/// State for the Script area: the act files, the joined script, the caret
/// and navigator. Reads and writes go through `ProjectStore`.
@MainActor
@Observable
final class ScriptWorkspace {
    let store: ProjectStore

    /// The act file shown in the editor.
    var currentFile: String?
    var showingTitlePage = false
    /// The navigator's selected row.
    var selectedRow: String?
    var reveal: RevealRequest?
    var caret: ScriptCaret?
    private(set) var characterNoteNames: [String] = []
    private(set) var projectWords: [String] = []
    private(set) var openError: String?

    @ObservationIgnored private var parseCache: [String: (text: String, parsed: ParsedScript)] = [:]
    @ObservationIgnored private var bookCache: (key: [String], book: ScriptBook)?
    /// The row a reveal came from, so the navigator doesn't reveal it twice.
    @ObservationIgnored var lastRevealedRow: String?

    static let titlePagePath = "script/title-page.md"

    init(store: ProjectStore) {
        self.store = store
        refreshFiles()
        refreshAuxiliary()
    }

    var scriptFiles: [ProjectFile] {
        ScriptBook.scriptFiles(in: store.files[.script] ?? [])
    }

    var hasTitlePage: Bool {
        store.files[.script]?.contains { $0.relativePath == Self.titlePagePath } == true
    }

    /// Opens every act file so the navigator and autocomplete see the whole
    /// script. Call when the file list changes.
    func refreshFiles() {
        openError = nil
        for file in scriptFiles where store.documents[file.relativePath] == nil {
            do {
                _ = try store.document(at: file.relativePath)
            } catch {
                openError = "\(file.name): \(error.localizedDescription)"
            }
        }
        if let currentFile, !scriptFiles.contains(where: { $0.relativePath == currentFile }) {
            self.currentFile = nil
        }
        if currentFile == nil, !showingTitlePage {
            currentFile = scriptFiles.first?.relativePath
        }
    }

    /// Re-reads character notes and `dictionary/words.txt`.
    func refreshAuxiliary() {
        let notes = (store.files[.universe] ?? []).filter { $0.relativePath.hasPrefix("universe/characters/") && $0.name.hasSuffix(".md") }
        characterNoteNames = notes.flatMap { note in
            (try? store.readText(at: note.relativePath)).map(CharacterNotes.names(inNote:)) ?? []
        }
        projectWords = (try? store.readText(at: "dictionary/words.txt")).map(ScriptSpelling.words(fromWordList:)) ?? []
    }

    /// The whole script, parsed. Cached per file text.
    var book: ScriptBook {
        let files = scriptFiles.map(\.relativePath)
        var texts: [String] = []
        for path in files { texts.append(store.documents[path]?.text ?? "") }
        let key = zip(files, texts).flatMap { [$0, $1] }
        if let bookCache, bookCache.key == key { return bookCache.book }
        let parsed = zip(files, texts).map { path, text -> (String, ParsedScript) in
            if let cached = parseCache[path], cached.text == text { return (path, cached.parsed) }
            let result = ScriptParser.parse(text)
            parseCache[path] = (text, result)
            return (path, result)
        }
        let book = ScriptBook(parsed: parsed.map { (path: $0.0, parsed: $0.1) })
        bookCache = (key, book)
        return book
    }

    /// Lets the editor share its fresh parse instead of parsing twice.
    func cache(_ parsed: ParsedScript, text: String, for path: String) {
        parseCache[path] = (text, parsed)
    }

    var completionSources: ScriptCompletion.Sources {
        let book = book
        var characters = book.characters
        for name in characterNoteNames.map({ $0.uppercased() }) where !characters.contains(name) {
            characters.append(name)
        }
        return ScriptCompletion.Sources(characters: characters, locations: book.locations, times: book.times)
    }

    var ignoredWords: [String] {
        ScriptSpelling.ignoredWords(characters: book.characters + characterNoteNames, extra: projectWords)
    }

    /// Scene IDs used in act files other than `path`.
    func sceneIDs(excluding path: String) -> Set<String> {
        Set(book.scenes.filter { $0.file != path }.compactMap(\.scene.sceneID))
    }

    var currentScene: ScriptBook.Scene? {
        guard let caret, let index = caret.sceneIndex else { return nil }
        return book.scenes.filter { $0.file == caret.file }.dropFirst(index).first
    }

    // MARK: - Navigation

    func show(file path: String) {
        showingTitlePage = false
        currentFile = path
    }

    func showTitlePage() {
        showingTitlePage = true
    }

    func reveal(_ scene: ScriptBook.Scene, focus: Bool) {
        let line = scene.scene.headingLine
        let lines = store.documents[scene.file].map { ScriptParser.parse($0.text).lines } ?? []
        let location = lines.indices.contains(line) ? (lines[line].tagRange?.location ?? lines[line].range.upperBound) : 0
        showingTitlePage = false
        currentFile = scene.file
        reveal = RevealRequest(file: scene.file, location: location, focus: focus)
    }

    static func row(for scene: ScriptBook.Scene) -> String {
        "scene:" + (scene.scene.sceneID ?? scene.id)
    }

    // MARK: - Editing

    /// Reorders scenes within one act file (navigator drag).
    func moveScene(in path: String, from: Int, to: Int) {
        guard let document = store.documents[path] else { return }
        let moved = ScriptEditing.movingScene(in: document.text, from: from, to: to)
        if moved != document.text { document.text = moved }
    }

    /// Moves the scene under the caret up or down within its file.
    func moveCurrentScene(by delta: Int) {
        guard let caret, let index = caret.sceneIndex else { return }
        let count = book.scenes.filter { $0.file == caret.file }.count
        let target = index + delta
        guard target >= 0, target < count else { return }
        moveScene(in: caret.file, from: index, to: delta > 0 ? target + 1 : target)
        if let scene = book.scenes.filter({ $0.file == caret.file }).dropFirst(target).first {
            reveal(scene, focus: true)
        }
    }

    func createScriptFile() {
        do {
            let document = try store.createTextFile(at: "script/script.md")
            refreshFiles()
            show(file: document.relativePath)
        } catch {
            openError = error.localizedDescription
        }
    }
}
