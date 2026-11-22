import AppKit
import Foundation
import Observation
import PDFKit
import SlateCore
import SlateExport

/// Where the editor should put the caret and scroll to.
struct RevealRequest: Equatable {
    let file: String
    let location: Int
    let focus: Bool
    /// Characters to select from `location`.
    var length = 0
    let token = UUID()
}

/// The caret as the editor last reported it.
struct ScriptCaret: Equatable {
    var file: String
    var location: Int
    var kind: ScriptElementKind
    var sceneIndex: Int?
    /// Selected words on one line, for anchoring margin notes and to-dos.
    var selection: String? = nil
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
    /// The project's dictionary, for spell check and defined-word underlines.
    var dictionary: DictionaryModel?
    private(set) var openError: String?
    /// Draft view (editable) or Page view (the printed pages).
    var showingPages = false
    var showingMargin = true
    let margin: MarginModel
    /// The latest exact page layout, made 300 ms after typing stops.
    private(set) var paginated: PaginatedScript?
    /// Bumped whenever `paginated` changes, so Page view knows to redraw.
    private(set) var paginationVersion = 0

    @ObservationIgnored private var parseCache: [String: (text: String, parsed: ParsedScript)] = [:]
    @ObservationIgnored private var bookCache: (key: [String], exact: Bool, book: ScriptBook)?
    @ObservationIgnored private var paginatedKey: [String]?
    @ObservationIgnored private var pendingKey: [String]?
    @ObservationIgnored private var paginationTask: Task<Void, Never>?
    /// The row a reveal came from, so the navigator doesn't reveal it twice.
    @ObservationIgnored var lastRevealedRow: String?
    /// Links: the project's link graph, and what ⌘-click on a link does.
    @ObservationIgnored var linkGraph: () -> LinkGraph = { .empty }
    @ObservationIgnored var followLink: (String) -> Bool = { _ in false }
    @ObservationIgnored var linkPreview: (String) -> NSViewController? = { _ in nil }
    /// Dictionary words: hover card, ⌘-click and context-menu items.
    @ObservationIgnored var dictionaryActions = DictionaryActions.none
    /// Told about every edit to an act file, for the link index.
    @ObservationIgnored var textDidChange: ((String, String) -> Void)?

    static let titlePagePath = "script/title-page.md"

    init(store: ProjectStore) {
        self.store = store
        margin = MarginModel(store: store)
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

    /// Re-reads character notes.
    func refreshAuxiliary() {
        let notes = (store.files[.universe] ?? []).filter { $0.relativePath.hasPrefix("universe/characters/") && $0.name.hasSuffix(".md") }
        characterNoteNames = notes.flatMap { note in
            (try? store.readText(at: note.relativePath)).map(CharacterNotes.names(inNote:)) ?? []
        }
    }

    var publishSettings: PublishSettings { PublishSettings(manifest: store.manifest) }

    /// The whole script, parsed. Cached per file text. Eighths and pages are
    /// exact once the paginator has caught up with the latest text.
    var book: ScriptBook {
        let files = scriptFiles.map(\.relativePath)
        var texts: [String] = []
        for path in files { texts.append(store.documents[path]?.text ?? "") }
        let key = zip(files, texts).flatMap { [$0, $1] } + [String(describing: publishSettings)]
        let exact = paginated != nil && paginatedKey == key
        if let bookCache, bookCache.key == key, bookCache.exact == exact { return bookCache.book }
        let parsed = zip(files, texts).map { path, text -> (String, ParsedScript) in
            if let cached = parseCache[path], cached.text == text { return (path, cached.parsed) }
            let result = ScriptParser.parse(text)
            parseCache[path] = (text, result)
            return (path, result)
        }
        let book = ScriptBook(parsed: parsed.map { (path: $0.0, parsed: $0.1) }, paginated: exact ? paginated : nil)
        bookCache = (key, exact, book)
        if !exact { schedulePagination(key: key, parsed: parsed.map(\.1)) }
        return book
    }

    private func schedulePagination(key: [String], parsed: [ParsedScript]) {
        guard pendingKey != key else { return }
        pendingKey = key
        paginationTask?.cancel()
        let settings = publishSettings
        paginationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Paginator(settings: settings).paginate(parsed)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.paginatedKey = key
            self.paginated = result
            self.paginationVersion += 1
        }
    }

    // MARK: - Publish

    /// What Publish reads: title page, act files in order, settings.
    func scriptSource() -> ScriptSource {
        ScriptSource(
            projectName: store.manifest.name,
            titlePage: (try? store.readText(at: Self.titlePagePath)) ?? "",
            files: scriptFiles.map { ($0.name, store.documents[$0.relativePath]?.text ?? "") },
            settings: publishSettings
        )
    }

    /// Page view's page for the caret (counting the title page).
    var caretPageIndex: Int? {
        guard let caret, let paginated, let file = scriptFiles.firstIndex(where: { $0.relativePath == caret.file }),
              let document = store.documents[caret.file] else { return nil }
        let line = ScriptParser.parse(document.text).lineIndex(containing: caret.location)
        guard let page = paginated.pageIndex(for: SourceRef(file: file, line: line)) else { return nil }
        return page + (TitlePage.parse(scriptSource().titlePage).isEmpty ? 0 : 1)
    }

    /// Writes an export to `exports/` and returns where it went.
    @discardableResult
    func export(_ format: ExportFormat) throws -> URL {
        store.saveAll()
        let url = try Publisher.export(format, scriptSource(), projectRoot: store.rootURL)
        store.rescan()
        return url
    }

    /// Exports and shows the file in Finder.
    func publish(_ format: ExportFormat) {
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try export(format)])
        } catch {
            SlateAppModel.showError("Couldn't publish", error)
        }
    }

    /// Prints with the same renderer as the PDF.
    func printScript() {
        guard let document = PDFDocument(data: Publisher.pdf(scriptSource())),
              let operation = document.printOperation(for: .shared, scalingMode: .pageScaleNone, autoRotate: false)
        else { return }
        operation.jobTitle = store.manifest.name
        operation.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }

    func updatePublishSettings(_ change: (inout PublishSettings) -> Void) {
        var settings = publishSettings
        change(&settings)
        do {
            try store.updateManifest { settings.apply(to: &$0) }
        } catch {
            SlateAppModel.showError("Couldn't save the setting", error)
        }
    }

    /// Lets the editor share its fresh parse instead of parsing twice.
    func cache(_ parsed: ParsedScript, text: String, for path: String) {
        parseCache[path] = (text, parsed)
        textDidChange?(path, text)
    }

    var completionSources: ScriptCompletion.Sources {
        let book = book
        var characters = book.characters
        for name in characterNoteNames.map({ $0.uppercased() }) where !characters.contains(name) {
            characters.append(name)
        }
        return ScriptCompletion.Sources(characters: characters, locations: book.locations, times: book.times)
    }

    /// Character names from the script and notes, which spell check accepts.
    var characterNames: [String] { book.characters + characterNoteNames }

    var spelling: EditorSpelling {
        dictionary?.spelling(for: .script, characters: characterNames) ?? .none
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

    /// The scene ID at the caret, if the caret is in a tagged scene.
    var currentSceneID: String? { currentScene?.scene.sceneID }

    /// Scene IDs in script order, for sorting margin items.
    var sceneOrder: [String] { book.scenes.compactMap(\.scene.sceneID) }

    func scene(withID id: String) -> ScriptBook.Scene? {
        book.scenes.first { $0.scene.sceneID == id }
    }

    /// Shows a scene and, if given, selects the quoted words in it.
    func reveal(sceneID: String, quote: String?) {
        guard let scene = scene(withID: sceneID) else { return }
        let row = Self.row(for: scene)
        lastRevealedRow = row
        selectedRow = row
        guard let quote, let document = store.documents[scene.file],
              let range = MarginQuote.range(of: quote, in: document.text, within: scene.scene.range) else {
            reveal(scene, focus: true)
            return
        }
        showingTitlePage = false
        showingPages = false
        currentFile = scene.file
        reveal = RevealRequest(file: scene.file, location: range.location, focus: true, length: range.length)
    }

    /// Shows an act file with the caret at a UTF-16 location.
    func reveal(file path: String, location: Int, focus: Bool = true) {
        showingTitlePage = false
        showingPages = false
        currentFile = path
        reveal = RevealRequest(file: path, location: location, focus: focus)
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

    /// Adds `HEADING {#sNNN}` (forced with `.` if needed) at the end of the last act file (Rough draft
    /// › Turn into Scene). Returns the file it went into.
    @discardableResult
    func appendSceneStub(heading: String) -> String? {
        if scriptFiles.isEmpty { createScriptFile() }
        guard let path = scriptFiles.last?.relativePath, let document = store.documents[path] ?? (try? store.document(at: path)) else { return nil }
        let id = ScriptBook.nextSceneID(existing: book.sceneIDs)
        let title = heading.trimmingCharacters(in: .whitespaces).uppercased()
        var text = document.text
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty, !text.hasSuffix("\n\n") { text += "\n" }
        let heading = ScriptEditing.convert(title, to: .sceneHeading)
        let stub = "\(heading) {#\(id)}\n"
        let location = (text as NSString).length + (heading as NSString).length
        document.text = text + stub
        reveal(file: path, location: location)
        return path
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
