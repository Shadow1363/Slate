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
    public let quickOpen: @MainActor () -> Void
    public let findInProject: @MainActor () -> Void
    public let newNote: @MainActor () -> Void
    public let toggleInspector: @MainActor () -> Void
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
        .navigationSubtitle(store.map { $0.rootURL.deletingLastPathComponent().path(percentEncoded: false) } ?? "")
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

    init(store: ProjectStore) {
        self.store = store
        _session = State(initialValue: ProjectSession(store: store))
    }

    var body: some View {
        @Bindable var session = session
        NavigationSplitView {
            List(ProjectArea.allCases, selection: $session.area) { area in
                Label(area.title, systemImage: area.systemImage)
                    .badge(Text("⌘\(area.shortcutNumber)").foregroundStyle(.tertiary))
                    .tag(area)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } content: {
            Group {
                switch session.area ?? .script {
                case .script: ScriptNavigator(workspace: session.script)
                case .universe: UniverseNavigator(session: session)
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
                case let area:
                    if let selectedFile = session.selectedFile {
                        DocumentPane(store: store, relativePath: selectedFile, close: { session.selectedFile = nil })
                            .id(selectedFile)
                    } else {
                        AreaPlaceholder(area: area)
                    }
                }
            }
            .inspector(isPresented: $session.showingInspector) {
                LinksInspector(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        session.showingInspector.toggle()
                    } label: {
                        Label("Links", systemImage: "sidebar.trailing")
                    }
                    .help("Show backlinks (⌥⌘0)")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = store.manifestError {
                Banner(systemImage: "exclamationmark.triangle.fill", message: error) {}
            }
        }
        .onChange(of: session.area) { session.selectedFile = nil }
        .onChange(of: store.files) { session.filesChanged() }
        .sheet(item: $session.sheet) { sheet in
            switch sheet {
            case .jumpToScene: JumpToSceneSheet(workspace: session.script)
            case .quickOpen: QuickOpenSheet(session: session)
            case .search: ProjectSearchSheet(session: session)
            case .rename(let path, let proposed): RenameNoteSheet(session: session, path: path, proposed: proposed)
            case .newNote(let type, let name): NewNoteSheet(session: session, type: type, name: name)
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
            publish: { session.script.publish($0) },
            printScript: { session.script.printScript() },
            togglePageView: {
                session.area = .script
                session.script.showingPages.toggle()
            },
            quickOpen: { session.sheet = .quickOpen },
            findInProject: { session.sheet = .search },
            newNote: { session.sheet = .newNote(type: nil, name: "") },
            toggleInspector: { session.showingInspector.toggle() }
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
        case .storyboard: "Boards arrive in Milestone 9 and the animatic player in Milestone 10."
        case .dictionary: "Terms and project spell check arrive in Milestone 6."
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
