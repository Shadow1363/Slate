import AppKit
import Observation
import SlateCore
import SwiftUI

/// Everything one project window shares: the store, the link index, the
/// Script workspace, which area and file are showing, and the sheets.
/// Links, search results and Quick Open all navigate through `open(_:)`.
@MainActor
@Observable
final class ProjectSession {
    enum Sheet: Identifiable {
        case jumpToScene
        case quickOpen
        case search
        /// Rename a note, optionally with a name already typed.
        case rename(String, String?)
        /// New note; the name is pre-filled when creating from a link.
        case newNote(type: String?, name: String)
        case addTodo(sceneID: String?, quote: String?)
        case editTodo(MarginTodo)
        case addMarginNote(sceneID: String?, quote: String?)
        case editNote(MarginNote)
        /// Add or edit a dictionary word; `word` pre-fills a new entry.
        case wordEntry(WordEntry?, word: String)
        /// Universe › Templates…, optionally opened on one template.
        case templates(String?)

        var id: String {
            switch self {
            case .jumpToScene: "jump"
            case .quickOpen: "quick"
            case .search: "search"
            case .rename(let path, _): "rename:" + path
            case .newNote(let type, let name): "new:\(type ?? ""):\(name)"
            case .addTodo: "addTodo"
            case .editTodo(let todo): "editTodo:" + todo.id
            case .addMarginNote: "addMarginNote"
            case .editNote(let note): "editNote:" + note.id
            case .wordEntry(let entry, let word): "word:\(entry?.id ?? ""):\(word)"
            case .templates: "templates"
            }
        }
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case links, define
        var id: String { rawValue }
        var title: String { self == .links ? "Links" : "Define" }
    }

    let store: ProjectStore
    let links: LinkIndex
    let script: ScriptWorkspace
    let dictionary: DictionaryModel
    let storyboard: StoryboardModel

    var area: ProjectArea? = .script
    /// The open file in Storyboard (a temporary file list).
    var selectedFile: String?
    /// The word showing in the Dictionary area.
    var dictionarySelection: DictionarySelection?
    var dictionaryQuery = ""
    /// The Dictionary area shows `words.md` as text instead of the book.
    var showingWordBookSource = false
    var inspectorTab: InspectorTab = .links
    /// The words selected in the focused editor (for the Define panel).
    var selectedText: String?
    /// The open note or file in Universe.
    var universeSelection: String?
    /// Caret placement for the Markdown editors.
    var noteReveal: RevealRequest?
    /// An item for the open map to point out ("Show on Map").
    var mapReveal: MapRevealRequest?
    var showingInspector = false
    var sheet: Sheet?
    /// A path whose name field should take focus (a note just created).
    var focusNameField: String?
    private(set) var templates: [NoteTemplate] = []
    /// Search text, kept between openings of Find in Project.
    var searchQuery = ""

    @ObservationIgnored private var indexTasks: [String: Task<Void, Never>] = [:]

    static var globalTemplatesFolder: URL {
        SlateAppModel.applicationSupport.appending(path: "Templates", directoryHint: .isDirectory)
    }

    init(store: ProjectStore, globalWordsURL: URL = GlobalWords.defaultURL) {
        self.store = store
        links = LinkIndex(store: store)
        script = ScriptWorkspace(store: store)
        dictionary = DictionaryModel(store: store, globalURL: globalWordsURL)
        storyboard = StoryboardModel(store: store, script: script)
        refreshTemplates()
        script.dictionary = dictionary
        script.linkGraph = { [weak self] in self?.links.graph ?? .empty }
        // In the script, a link opens in the margin so you stay in the scene.
        script.followLink = { [weak self] target in self?.peekLink(target) ?? false }
        script.linkPreview = { [weak self] target in self?.linkPreview(target) }
        script.textDidChange = { [weak self] path, text in self?.textDidChange(path: path, text: text) }
        universeSelection = ProjectLayout.draft
        script.dictionaryActions = dictionaryActions(inScript: true)
        script.showFrames = { [weak self] sceneID, line in
            guard let self else { return }
            StoryboardActions.showFrames(sceneID: sceneID, line: line, session: self)
        }
    }

    /// A new sketch for the selected frame's scene, the focused board row, or the scene at the script caret.
    func newSketch() {
        let board = storyboard
        let fromSelection = board.selection.flatMap { board.scene(forFolder: $0.folder)?.scene.sceneID }
        let fromRow = board.focusedRow.flatMap { id in board.scenes.contains { $0.scene.sceneID == id } ? id : nil }
        let fromCaret = script.caret.flatMap { caret -> String? in
            guard let file = script.book.files.first(where: { $0.path == caret.file }) else { return nil }
            let line = file.parsed.lineIndex(containing: caret.location)
            return file.parsed.sceneIndex(containingLine: line).flatMap { file.parsed.scenes[$0].sceneID }
        }
        guard let id = fromSelection ?? fromRow ?? fromCaret ?? board.scenes.first?.scene.sceneID else { return }
        area = .storyboard
        board.focusedRow = id
        board.sketchTarget = .init(sceneID: id, file: nil)
    }

    /// Call when `store.files` changes.
    func filesChanged() {
        script.refreshFiles()
        script.refreshAuxiliary()
        links.refresh()
        dictionary.refresh()
        refreshTemplates()
        storyboard.refresh()
        if let selection = universeSelection, !exists(selection) { universeSelection = nil }
        if let selection = selectedFile, !exists(selection) { selectedFile = nil }
    }

    /// Call when files may have changed on disk without the file list changing.
    func contentsChanged() {
        links.refresh()
        storyboard.refresh()
    }

    func refreshTemplates() {
        let loaded = NoteTemplates.load(
            projectTemplates: store.rootURL.appending(path: ProjectLayout.templates, directoryHint: .isDirectory),
            globalTemplates: Self.globalTemplatesFolder
        )
        if loaded != templates { templates = loaded }
    }

    func template(for type: String?) -> NoteTemplate? {
        NoteTemplates.matching(type, in: templates) ?? templates.first { $0.type == "note" }
    }

    var allPaths: [String] { store.files.values.flatMap { $0 }.map(\.relativePath) }

    func exists(_ path: String) -> Bool {
        store.files.values.contains { $0.contains { $0.relativePath == path } }
    }

    /// Re-indexes a file shortly after it's edited (before it's saved).
    func textDidChange(path: String, text: String) {
        if path == WordBook.path { dictionary.refresh() }
        guard IndexedFile.isIndexed(path) else { return }
        indexTasks[path]?.cancel()
        indexTasks[path] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.links.update(path: path, text: text)
            self.indexTasks[path] = nil
        }
    }

    // MARK: - Navigation

    /// Opens any project file in the right area, optionally at a location.
    func open(_ path: String, location: Int? = nil) {
        let area = path.split(separator: "/").first.map(String.init)
        switch area {
        case ProjectLayout.universe:
            self.area = .universe
            universeSelection = path
            if let location { noteReveal = RevealRequest(file: path, location: location, focus: true) }
        case ProjectLayout.script where script.scriptFiles.contains(where: { $0.relativePath == path }):
            self.area = .script
            script.reveal(file: path, location: location ?? 0)
        case ProjectLayout.dictionary where path == WordBook.path:
            self.area = .dictionary
            showingWordBookSource = true
            if let location { noteReveal = RevealRequest(file: path, location: location, focus: true) }
        case ProjectLayout.script where path == ScriptWorkspace.titlePagePath:
            self.area = .script
            script.showTitlePage()
        default:
            self.area = ProjectArea.allCases.first { $0.folder == area } ?? .universe
            if self.area == .universe { universeSelection = path } else { selectedFile = path }
        }
    }

    /// Opens a scene from Quick Open or a backlink.
    func open(scene: ScriptBook.Scene) {
        area = .script
        let row = ScriptWorkspace.row(for: scene)
        script.lastRevealedRow = row
        script.selectedRow = row
        script.reveal(scene, focus: true)
    }

    func open(sceneID: String) {
        if let scene = script.book.scenes.first(where: { $0.scene.sceneID == sceneID }) { open(scene: scene) }
    }

    /// ⌘-click on a link: opens the note, or offers to create it.
    @discardableResult
    func followLink(_ target: String) -> Bool {
        if let resolution = links.graph.resolve(target) {
            open(resolution.path)
        } else {
            sheet = .newNote(type: nil, name: target)
        }
        return true
    }

    /// Shows a linked note in the Script margin (or offers to create it).
    @discardableResult
    func peekLink(_ target: String) -> Bool {
        guard let resolution = links.graph.resolve(target) else {
            sheet = .newNote(type: nil, name: target)
            return true
        }
        script.showingMargin = true
        script.margin.peek = resolution.path
        return true
    }

    /// The hover preview for a link, or nil if it doesn't resolve.
    func linkPreview(_ target: String) -> NSViewController? {
        guard let path = links.graph.resolve(target)?.path else { return nil }
        let card = NotePreviewCard(session: self, path: path, bodyLimit: 400)
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        let controller = NSHostingController(rootView: card)
        controller.sizingOptions = .preferredContentSize
        return controller
    }

    /// ⇧⌘T / ⌥⌘T: anchored to the caret's scene and the selected words.
    func addTodoAtCaret() {
        area = .script
        sheet = .addTodo(sceneID: script.currentSceneID, quote: script.caret?.selection)
    }

    func addMarginNoteAtCaret() {
        area = .script
        sheet = .addMarginNote(sceneID: script.currentSceneID, quote: script.caret?.selection)
    }

    // MARK: - Notes

    /// Creates a note from a template and opens it. Returns its path.
    @discardableResult
    func createNote(template: NoteTemplate, name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingIDs = Set(links.graph.notes.compactMap(\.noteID))
        let path = template.path(forName: name.isEmpty ? "Untitled \(template.label)" : name, existing: Set(allPaths))
        let text = template.newNote(name: name.isEmpty ? "Untitled \(template.label)" : name, id: template.newID(existing: existingIDs))
        try store.createTextFile(at: path, contents: text)
        links.refresh()
        open(path)
        focusNameField = name.isEmpty ? path : nil
        return path
    }

    func trash(_ path: String) {
        do {
            try store.trashFile(path)
            if universeSelection == path { universeSelection = nil }
            links.refresh()
        } catch {
            SlateAppModel.showError("Couldn't move “\((path as NSString).lastPathComponent)” to the Trash", error)
        }
    }

    func renamePlan(for path: String, to name: String) -> RenameRefactor.Plan? {
        RenameRefactor.plan(renaming: path, to: name, in: links.graph, existingPaths: Set(allPaths))
    }

    func rename(_ plan: RenameRefactor.Plan, updateLinks: Bool) {
        do {
            let newPath = try RenameRefactor.apply(plan, updateLinks: updateLinks, store: store)
            links.refresh()
            for document in store.documents.values where plan.edits.contains(where: { $0.path == document.relativePath }) {
                links.update(path: document.relativePath, text: document.text)
            }
            if universeSelection == plan.notePath { universeSelection = newPath }
            script.refreshAuxiliary()
            dictionary.refresh()
        } catch {
            SlateAppModel.showError("Couldn't rename “\(plan.oldName)”", error)
        }
    }

    // MARK: - Quick Open

    var quickOpenItems: [QuickOpen.Item] {
        var items: [QuickOpen.Item] = []
        let graph = links.graph
        for note in graph.notes {
            items.append(QuickOpen.Item(kind: .note, title: note.name, subtitle: template(for: note.type)?.label ?? note.type?.capitalized ?? "Note",
                                        path: note.path, keywords: note.aliases))
        }
        for scene in script.book.scenes {
            items.append(QuickOpen.Item(kind: .scene, title: scene.scene.heading.isEmpty ? "Untitled scene" : scene.scene.heading,
                                        subtitle: "Scene \(scene.number)", path: scene.file, sceneRow: ScriptWorkspace.row(for: scene)))
        }
        let notePaths = Set(graph.notes.map(\.path))
        for path in allPaths.sorted() where !notePaths.contains(path) && !path.hasPrefix(ProjectLayout.exports + "/") {
            items.append(QuickOpen.Item(kind: .file, title: (path as NSString).lastPathComponent, subtitle: (path as NSString).deletingLastPathComponent, path: path))
        }
        return items
    }

    func open(_ item: QuickOpen.Item) {
        if item.kind == .scene, let row = item.sceneRow,
           let scene = script.book.scenes.first(where: { ScriptWorkspace.row(for: $0) == row }) {
            open(scene: scene)
        } else {
            open(item.path)
        }
    }
}
