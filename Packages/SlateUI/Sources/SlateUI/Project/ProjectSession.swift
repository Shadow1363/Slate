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
        /// Tags for one scene.
        case sceneTags(String)

        var id: String {
            switch self {
            case .jumpToScene: "jump"
            case .rename(let path, _): "rename:" + path
            case .newNote(let type, let name): "new:\(type ?? ""):\(name)"
            case .addTodo: "addTodo"
            case .editTodo(let todo): "editTodo:" + todo.id
            case .addMarginNote: "addMarginNote"
            case .editNote(let note): "editNote:" + note.id
            case .wordEntry(let entry, let word): "word:\(entry?.id ?? ""):\(word)"
            case .templates: "templates"
            case .sceneTags(let id): "sceneTags:" + id
            }
        }
    }

    /// The tabs of the right-hand sidebar. Which ones show depends on the area.
    enum SidebarTab: String, CaseIterable, Identifiable {
        case todos, notes, links, define
        var id: String { rawValue }
        var title: String {
            switch self {
            case .todos: "To-dos"
            case .notes: "Notes"
            case .links: "Links"
            case .define: "Define"
            }
        }

        static func tabs(for area: ProjectArea?) -> [SidebarTab] {
            switch area ?? .script {
            case .script: [.todos, .notes, .define]
            case .universe: [.todos, .links, .define]
            default: [.links, .define]
            }
        }
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
    /// The last tab picked in each area's sidebar.
    var sidebarTabs: [ProjectArea: SidebarTab] = [:]
    /// The words selected in the focused editor (for the Define panel).
    var selectedText: String?
    /// The open note or file in Universe.
    var universeSelection: String?
    /// The Search panel (⌘K) while it's open.
    var spotlight: SpotlightModel?
    /// A timeline event or map place to select when its file shows.
    var pendingItemSelection: PendingSelection?
    @ObservationIgnored private weak var responderBeforeSearch: NSResponder?
    /// Open notes and headings in the Universe sidebar's index.
    let outline: OutlineState
    /// Caret placement for the Markdown editors.
    var noteReveal: RevealRequest?
    /// An item for the open map to point out ("Show on Map").
    var mapReveal: MapRevealRequest?
    /// The right-hand sidebar (to-dos, margin notes, links, define).
    var showingSidebar: Bool {
        didSet { UserDefaults.standard.set(showingSidebar, forKey: Self.sidebarShownKey) }
    }
    static let sidebarShownKey = "project.sidebarShown"
    var sheet: Sheet?
    /// A path whose name field should take focus (a note just created).
    var focusNameField: String?
    private(set) var templates: [NoteTemplate] = []
    /// Deleted templates that can be restored (type, label).
    private(set) var removedTemplates: [(type: String, label: String)] = []
    /// Search text, kept between openings of Find in Project.

    /// An animatic or boards export in progress.
    /// The Universe area's margin (TODO comments in notes).
    let noteMargin: NoteMarginModel
    var exportJob: ExportJob?
    /// Import Voice Note…, while it transcribes.
    var voiceImport: VoiceImportJob?
    @ObservationIgnored var animaticWindow: AnimaticWindowController?

    @ObservationIgnored private var indexTasks: [String: Task<Void, Never>] = [:]

    static var globalTemplatesFolder: URL {
        SlateAppModel.applicationSupport.appending(path: "Templates", directoryHint: .isDirectory)
    }

    init(store: ProjectStore, globalWordsURL: URL = GlobalWords.defaultURL) {
        self.store = store
        showingSidebar = UserDefaults.standard.object(forKey: Self.sidebarShownKey) as? Bool ?? true
        outline = OutlineState(projectRoot: store.rootURL)
        links = LinkIndex(store: store)
        script = ScriptWorkspace(store: store)
        noteMargin = NoteMarginModel(store: store)
        dictionary = DictionaryModel(store: store, globalURL: globalWordsURL)
        storyboard = StoryboardModel(store: store, script: script)
        refreshTemplates()
        script.dictionary = dictionary
        script.linkGraph = { [weak self] in self?.links.graph ?? .empty }
        // In the script, a link opens in the margin so you stay in the scene.
        script.followLink = { [weak self] target in self?.peekLink(target) ?? false }
        script.linkPreview = { [weak self] target in self?.linkPreview(target) }
        script.textDidChange = { [weak self] path, text in self?.textDidChange(path: path, text: text) }
        if store.files[.universe]?.contains(where: { $0.relativePath == ProjectLayout.draft }) == true { universeSelection = ProjectLayout.draft }
        script.dictionaryActions = dictionaryActions(inScript: true)
        script.showFrames = { [weak self] sceneID, line in
            guard let self else { return }
            StoryboardActions.showFrames(sceneID: sceneID, line: line, session: self)
        }
    }

    /// The sidebar tab for the current area: the last one picked there, or its first.
    var sidebarTab: SidebarTab {
        get {
            let tabs = SidebarTab.tabs(for: area)
            if let saved = sidebarTabs[area ?? .script], tabs.contains(saved) { return saved }
            return tabs[0]
        }
        set { sidebarTabs[area ?? .script] = newValue }
    }

    /// Opens the sidebar on a tab (if this area has it).
    func showSidebar(_ tab: SidebarTab) {
        if SidebarTab.tabs(for: area).contains(tab) { sidebarTab = tab }
        showingSidebar = true
    }

    /// ⇧⌘M: the sidebar on To-dos, or hides it when To-dos is already showing.
    func toggleTodos() {
        guard SidebarTab.tabs(for: area).contains(.todos) else {
            showingSidebar.toggle()
            return
        }
        if showingSidebar && sidebarTab == .todos { showingSidebar = false } else { showSidebar(.todos) }
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
        script.refreshProduction()
        script.refreshOtherFilms()
        links.refresh()
        storyboard.refresh()
    }

    func refreshTemplates() {
        let loaded = NoteTemplates.load(
            projectTemplates: store.rootURL.appending(path: ProjectLayout.templates, directoryHint: .isDirectory),
            globalTemplates: Self.globalTemplatesFolder
        )
        if loaded != templates { templates = loaded }
        let removed = NoteTemplates.removed(
            projectTemplates: store.rootURL.appending(path: ProjectLayout.templates, directoryHint: .isDirectory),
            globalTemplates: Self.globalTemplatesFolder
        )
        if removed.map(\.type) != removedTemplates.map(\.type) { removedTemplates = removed }
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
        case ProjectLayout.script where Films.isActFile(path):
            self.area = .script
            if let film = Films.film(containing: path, in: script.films) { script.select(film: film) }
            script.reveal(file: path, location: location ?? 0)
        case ProjectLayout.dictionary where path == WordBook.path:
            self.area = .dictionary
            showingWordBookSource = true
            if let location { noteReveal = RevealRequest(file: path, location: location, focus: true) }
        case ProjectLayout.script where (path as NSString).lastPathComponent == "title-page.md"
            && Films.film(containing: path, in: script.films)?.titlePagePath == path:
            self.area = .script
            if let film = Films.film(containing: path, in: script.films) { script.select(film: film) }
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
        if let film = script.film(containingScene: sceneID) { script.select(film: film) }
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
        showingSidebar = true
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
        // In a note (or the draft), a to-do is a `%% TODO: %%` comment where you're writing.
        if area != .script, let textView = NSApp.keyWindow?.firstResponder as? SlateTextView, textView.isEditable {
            CommentTodoEditing.insertNew(in: textView)
            return
        }
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

    /// Opens Search, optionally with a query typed (`!text `, `!t storm `).
    /// With no query, the shortcut toggles it: pressed again, Search closes.
    func showSearch(_ query: String = "") {
        if let spotlight {
            guard !query.isEmpty else {
                closeSearch()
                return
            }
            spotlight.reload()
            spotlight.query = query
            return
        }
        // Take the keyboard from the editor so the search field can have it,
        // and remember where it was to give it back.
        let window = NSApp.keyWindow
        responderBeforeSearch = window?.firstResponder
        window?.makeFirstResponder(nil)
        spotlight = SpotlightModel(session: self, query: query)
    }

    /// Closes Search and puts the keyboard back where it was (unless a result moved it).
    func closeSearch(restoringFocus: Bool = true) {
        guard spotlight != nil else { return }
        spotlight = nil
        let previous = responderBeforeSearch
        responderBeforeSearch = nil
        guard restoringFocus, let previous, let window = (previous as? NSView)?.window else { return }
        DispatchQueue.main.async { window.makeFirstResponder(previous) }
    }

    /// Makes `universe/draft.md` again after it was deleted.
    func createDraft() {
        do {
            _ = try store.createTextFile(at: ProjectLayout.draft, contents: "# \(store.manifest.name)\n\n")
            store.rescan()
            area = .universe
            universeSelection = ProjectLayout.draft
        } catch {
            SlateAppModel.showError("Couldn't make the rough draft", error)
        }
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
            outline.move(plan.notePath, to: newPath)
            script.refreshAuxiliary()
            dictionary.refresh()
        } catch {
            SlateAppModel.showError("Couldn't rename “\(plan.oldName)”", error)
        }
    }

}
