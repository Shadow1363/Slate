import AppKit
import SlateCore
import SlateExport
import SwiftUI

/// Actions the menu bar can send to the focused project window.
public struct ProjectActions {
    public let selectArea: @MainActor (ProjectArea) -> Void
    public let save: @MainActor () -> Void
    public let jumpToScene: @MainActor () -> Void
    public let moveScene: @MainActor (Int) -> Void
    public let publish: @MainActor (ExportFormat) -> Void
    public let printScript: @MainActor () -> Void
    public let togglePageView: @MainActor () -> Void
    /// Opens Search (⌘K), optionally with a query typed (`!text `).
    public let search: @MainActor (String) -> Void
    public let newNote: @MainActor () -> Void
    /// File › Import Voice Note…
    public let importVoiceNote: @MainActor () -> Void
    /// "New Note…", or "Add Word…" in the Dictionary.
    public let newItemTitle: String
    public let toggleInspector: @MainActor () -> Void
    public let addTodo: @MainActor () -> Void
    public let addMarginNote: @MainActor () -> Void
    public let toggleMargin: @MainActor () -> Void
    public let showAllTodos: @MainActor () -> Void
    public let defineSelection: @MainActor () -> Void
    public let newSketch: @MainActor () -> Void
    public let watchAnimatic: @MainActor () -> Void
    public let exportBoards: @MainActor (BoardsPDF.Layout) -> Void
    public let production: @MainActor (ProductionCommand) -> Void
    /// For the Production menu's titles.
    public let productionFile: ProductionFile
    public let script: @MainActor (ScriptCommand) -> Void
    public let focusMode: Bool
    public let typewriter: Bool
    /// The project's films (one unless it's a saga) and the open one's folder.
    public let films: [Film]
    public let currentFilm: String
    /// `project.json` › `theme`, or nil to follow Settings.
    public let projectTheme: String?
    public let setProjectTheme: @MainActor (String?) -> Void
    /// Edit › Find: the open file's find bar (`.editor`), a filter field, or nil (nothing to search).
    let findTarget: ProjectSession.FindTarget?
    /// ⌘F where there's no text editor: focuses the view's filter field.
    let focusFilter: @MainActor () -> Void
}

extension FocusedValues {
    @Entry public var projectActions: ProjectActions?
}

/// One project folder in its own window.
public struct ProjectWindow: View {
    let url: URL?

    @State private var store: ProjectStore?
    @State private var loadError: String?

    public init(url: URL?) {
        self.url = url
    }

    public var body: some View {
        Group {
            if let store {
                ProjectContent(store: store)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Can't Open Project", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle(store?.manifest.name ?? url?.lastPathComponent ?? "Slate")
        .slateThemed(projectOverride: store?.manifest.theme)
        .task(id: url) { open() }
        .onDisappear { store?.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store?.saveAll()
        }
    }

    private func open() {
        store?.close()
        store = nil
        guard let url else {
            loadError = "No project folder was given."
            return
        }
        do {
            let opened = try ProjectStore(rootURL: url)
            opened.startWatching()
            store = opened
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct ProjectContent: View {
    let store: ProjectStore
    @State private var session: ProjectSession
    @Environment(SlateAppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all
    /// What focus mode hid, to put back when it ends.
    @State private var beforeFocus: (columns: NavigationSplitViewVisibility, sidebar: Bool)?

    init(store: ProjectStore) {
        self.store = store
        _session = State(initialValue: ProjectSession(store: store))
    }

    var body: some View {
        @Bindable var session = session
        // The area (Universe, Script…) is picked from the title menu, not a column.
        NavigationSplitView(columnVisibility: $columns) {
            Group {
                switch session.area ?? .script {
                case .script: ScriptNavigator(workspace: session.script, session: session)
                case .universe: UniverseNavigator(session: session)
                case .dictionary: DictionaryNavigator(session: session)
                case .storyboard: StoryboardNavigator(session: session)
                case let area: AreaFileList(store: store, area: area, selection: $session.selectedFile)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            Group {
                switch session.area ?? .script {
                case .script:
                    ScriptDetail(workspace: session.script)
                case .universe:
                    UniverseDetail(session: session)
                case .dictionary:
                    DictionaryDetail(session: session)
                case .storyboard:
                    StoryboardDetail(session: session)
                case let area:
                    if let selectedFile = session.selectedFile {
                        DocumentPane(store: store, relativePath: selectedFile, close: { session.selectedFile = nil })
                            .id(selectedFile)
                    } else {
                        AreaPlaceholder(area: area)
                    }
                }
            }
            .inspector(isPresented: $session.showingSidebar) {
                SidebarView(session: session)
                    .inspectorColumnWidth(min: 220, ideal: 300, max: 420)
            }
        }
        .overlay(alignment: .top) {
            if let spotlight = session.spotlight {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { session.closeSearch() }
                    SpotlightPanel(model: spotlight) { opened in session.closeSearch(restoringFocus: !opened) }
                        .padding(.top, 48)
                }
                .transition(.opacity)
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                AreaSwitcher(area: $session.area)
            }
            SidebarToggleToolbar(session: session)
        }
        .onChange(of: store.files) { session.spotlight?.reload() }
        .safeAreaInset(edge: .top, spacing: 0) { UpdateBanner() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = store.manifestError {
                Banner(systemImage: "exclamationmark.triangle.fill", message: error) {}
            }
        }
        .onChange(of: session.area) {
            session.selectedFile = nil
            if session.area != .script { session.script.focusMode = false }
        }
        .onChange(of: session.script.focusMode) { _, on in
            if on {
                beforeFocus = (columns, session.showingSidebar)
                withAnimation {
                    columns = .detailOnly
                    session.showingSidebar = false
                }
            } else if let saved = beforeFocus {
                withAnimation {
                    columns = saved.columns
                    session.showingSidebar = saved.sidebar
                }
                beforeFocus = nil
            }
        }
        .onAppear {
            model.register(session)
            // Renames board folders to match headings, and moves boards whose scene is gone to orphans/.
            session.storyboard.tidyFolders(moveMissing: true)
        }
        .overlay(alignment: .bottom) {
            if let job = session.exportJob { ExportJobBar(job: job) }
            else if let job = session.voiceImport { VoiceImportBar(job: job) }
        }
        .onDisappear {
            session.closeAnimatic()
            session.dictionary.closeSpellDocument()
            session.storyboard.tidyFolders(moveMissing: true)
            model.unregister(session)
        }
        .onChange(of: model.jumpRequests[SlateAppModel.key(store.rootURL)], initial: true) { _, request in
            guard request != nil, let jump = model.takeJump(for: store.rootURL) else { return }
            if let path = jump.path, let range = jump.range {
                // A TODO: comment: open its file with the comment selected.
                session.open(path, range: range)
            } else {
                session.area = .script
                if let id = jump.sceneID { session.script.reveal(sceneID: id, quote: jump.quote) }
            }
        }
        // Margin to-dos, and TODO: comments in notes and the script (the link index updates as you type).
        .onChange(of: session.script.margin.todosText) { model.reschedule(root: store.rootURL) }
        .onChange(of: session.links.version) { model.reschedule(root: store.rootURL) }
        .onChange(of: store.files) { session.filesChanged() }
        .onChange(of: store.externalChangeCount) { session.contentsChanged() }
        .onChange(of: session.dictionary.projectText) { session.dictionary.refresh() }
        .sheet(item: $session.sheet) { sheet in
            switch sheet {
            case .jumpToScene: JumpToSceneSheet(workspace: session.script)
            case .rename(let path, let proposed): RenameNoteSheet(session: session, path: path, proposed: proposed)
            case .newNote(let type, let name): NewNoteSheet(session: session, type: type, name: name)
            case .addTodo(let sceneID, let quote): TodoSheet(session: session, editing: nil, sceneID: sceneID, quote: quote)
            case .editTodo(let todo): TodoSheet(session: session, editing: todo, sceneID: nil, quote: nil)
            case .addMarginNote(let sceneID, let quote): MarginNoteSheet(session: session, editing: nil, sceneID: sceneID, quote: quote)
            case .editNote(let note): MarginNoteSheet(session: session, editing: note, sceneID: nil, quote: nil)
            case .wordEntry(let entry, let word): WordEntrySheet(session: session, editing: entry, word: word)
            case .templates(let selected): TemplatesSheet(session: session, selected: selected)
            case .sceneTags(let id): SceneTagsSheet(session: session, sceneID: id)
            }
        }
        .focusedSceneValue(\.projectActions, ProjectActions(
            selectArea: { session.area = $0 },
            save: { store.saveAll() },
            jumpToScene: {
                session.area = .script
                session.sheet = .jumpToScene
            },
            moveScene: { delta in
                guard session.area == .script else { return }
                session.script.moveCurrentScene(by: delta)
            },
            publish: { session.publish($0) },
            printScript: { session.script.printScript() },
            togglePageView: {
                session.area = .script
                session.script.showingPages.toggle()
            },
            search: { session.showSearch($0) },
            newNote: {
                if session.area == .dictionary {
                    session.sheet = .wordEntry(nil, word: "")
                } else {
                    session.sheet = .newNote(type: nil, name: "")
                }
            },
            importVoiceNote: { session.importVoiceNotes() },
            newItemTitle: session.area == .dictionary ? "Add Word…" : "New Note…",
            toggleInspector: { session.showingSidebar.toggle() },
            addTodo: { session.addTodoAtCaret() },
            addMarginNote: { session.addMarginNoteAtCaret() },
            toggleMargin: { session.toggleTodos() },
            showAllTodos: {
                session.area = .script
                session.script.margin.peek = nil
                session.script.margin.scope = .all
                session.showSidebar(.todos)
            },
            defineSelection: { session.defineSelection() },
            newSketch: { session.newSketch() },
            watchAnimatic: { session.watch(.film) },
            exportBoards: { session.exportBoards($0) },
            production: { command in
                if case .sides = command { session.area = .script }
                session.script.perform(command)
            },
            productionFile: session.script.production,
            script: { command in
                if case .toggleTypewriter = command {} else { session.area = .script }
                session.script.perform(command)
            },
            focusMode: session.script.focusMode,
            typewriter: session.script.typewriter,
            films: session.script.films,
            currentFilm: session.script.film.folder,
            projectTheme: store.manifest.theme,
            setProjectTheme: { name in
                do {
                    try store.updateManifest { $0.theme = name }
                } catch {
                    SlateAppModel.showError("Couldn't save the project's theme", error)
                }
            },
            findTarget: session.findTarget,
            focusFilter: { session.focusFilter() }
        ))
    }
}

extension ProjectArea {
    var systemImage: String {
        switch self {
        case .universe: "globe.americas"
        case .script: "text.page"
        case .storyboard: "rectangle.split.3x3"
        case .dictionary: "character.book.closed"
        }
    }

    /// Which milestone brings the real editor for this area.
    var comingIn: String {
        switch self {
        case .universe: "Canvas, timeline and map arrive in Milestones 7–8."
        case .script: "The screenplay editor arrives in Milestone 2."
        case .storyboard: "Boards and the animatic player live here."
        case .dictionary: "Pick a word to see its page."
        }
    }
}

/// Temporary list of the files in an area folder. It is here so Milestone 1
/// can show files reloading; each area gets its real view later.
struct AreaFileList: View {
    let store: ProjectStore
    let area: ProjectArea
    @Binding var selection: String?

    var body: some View {
        let files = store.files[area] ?? []
        List(files, selection: $selection) { file in
            Label(file.pathInArea, systemImage: file.isText ? "doc.text" : "doc")
                .foregroundStyle(file.isText ? .primary : .secondary)
                .tag(file.relativePath)
                .contextMenu {
                    Button("Show in Finder") {
                        if let url = try? store.url(for: file.relativePath) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
        }
        .overlay {
            if files.isEmpty {
                ContentUnavailableView("No Files", systemImage: "folder", description: Text("\(area.folder)/ is empty."))
            }
        }
        .navigationTitle(area.title)
    }
}

struct AreaPlaceholder: View {
    let area: ProjectArea

    var body: some View {
        ContentUnavailableView {
            Label(area.title, systemImage: area.systemImage)
        } description: {
            Text(area.comingIn + "\nFor now, pick a file to view and edit it as plain text.")
        }
    }
}

/// The window's title: the current area's name. Clicking it lists every
/// area, with its icon, the current one ticked. ⌘1–⌘4 still switch.
struct AreaSwitcher: View {
    @Binding var area: ProjectArea?

    var body: some View {
        let current = area ?? .script
        Menu {
            ForEach(ProjectArea.allCases) { option in
                Toggle(isOn: Binding(get: { option == current }, set: { if $0 { area = option } })) {
                    Label(option.title, systemImage: option.systemImage)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(current.title)
                    .font(.title3.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch area (⌘1–⌘4)")
        .accessibilityLabel("Area: \(current.title)")
    }
}

/// The right-hand sidebar: one column whose tabs depend on the area
/// (Script: To-dos, Notes, Define; Universe: To-dos, Links, Define; others: Links, Define).
struct SidebarView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        let area = session.area ?? .script
        VStack(spacing: 0) {
            if area == .script, session.script.margin.peek != nil {
                // A linked note clicked in the script takes the whole sidebar until closed.
                MarginView(session: session, margin: session.script.margin, tab: .notes)
            } else {
                Picker("Sidebar", selection: $session.sidebarTab) {
                    ForEach(ProjectSession.SidebarTab.tabs(for: area)) { tab in
                        Text(tab == .spelling && session.spelling.count > 0 ? "\(tab.title) \(session.spelling.count)" : tab.title)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 4)
                Group {
                    switch session.sidebarTab {
                    case .todos where area == .universe:
                        NoteMarginView(session: session, margin: session.noteMargin)
                    case .todos, .notes:
                        MarginView(session: session, margin: session.script.margin, tab: session.sidebarTab)
                    case .links: LinksInspector(session: session)
                    case .define: DefineInspector(session: session)
                    case .spelling: SpellingPanel(session: session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(SpellingScanner(session: session))
    }
}
