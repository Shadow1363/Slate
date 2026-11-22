import AppKit
import SlateCore
import SwiftUI

enum HomeSection: Hashable {
    case all
    case recent
    case pinned
    case watched(URL)
}

/// The project library: every project folder Slate knows about.
public struct HomeView: View {
    @Environment(SlateAppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var section: HomeSection? = .all
    @State private var search = ""

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $section) {
                Section("Library") {
                    Label("All Projects", systemImage: "square.grid.2x2").tag(HomeSection.all)
                    Label("Recent", systemImage: "clock").tag(HomeSection.recent)
                    Label("Pinned", systemImage: "pin").tag(HomeSection.pinned)
                }
                Section("Watched Folders") {
                    ForEach(model.library.watchedFolders, id: \.self) { folder in
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .help(folder.path)
                            .tag(HomeSection.watched(folder))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ProjectGrid(entries: visibleEntries, emptyMessage: emptyMessage, open: open)
        }
        .navigationTitle(title)
        .searchable(text: $search, placement: .toolbar, prompt: "Search projects")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.showingNewProject = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
                .help("New Project (⌘N)")
                Button {
                    if let url = model.chooseProjectFolder() { openWindow(id: SlateWindowID.project, value: url) }
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .help("Open a project folder (⌘O)")
            }
        }
        .sheet(isPresented: $model.showingNewProject) {
            NewProjectSheet { url in openWindow(id: SlateWindowID.project, value: url) }
        }
        .task {
            model.library.scanWatchedFolders()
            model.library.refreshStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.library.refreshStatuses()
        }
        .frame(minWidth: 720, minHeight: 440)
        .slateThemed()
    }

    private var title: String {
        switch section ?? .all {
        case .all: "All Projects"
        case .recent: "Recent"
        case .pinned: "Pinned"
        case .watched(let folder): folder.lastPathComponent
        }
    }

    private var visibleEntries: [LibraryEntry] {
        let entries: [LibraryEntry] = switch section ?? .all {
        case .all: model.library.entries.sorted { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
        case .recent: model.library.recent
        case .pinned: model.library.pinned
        case .watched(let folder): model.library.entries(inWatchedFolder: folder)
        }
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.folderName.localizedCaseInsensitiveContains(search) }
    }

    private var emptyMessage: String {
        switch section ?? .all {
        case .all: "No projects yet. Create one with New Project, or open an existing folder."
        case .recent: "Projects you open show up here."
        case .pinned: "Right-click a project and choose Pin to keep it here."
        case .watched(let folder): "No projects in \(folder.path) yet."
        }
    }

    private func open(_ entry: LibraryEntry) {
        if let url = model.prepareToOpen(entry) {
            openWindow(id: SlateWindowID.project, value: url)
        }
    }
}

/// Window identifiers shared by the app and its views.
public enum SlateWindowID {
    public static let home = "home"
    public static let project = "project"
}

struct ProjectGrid: View {
    let entries: [LibraryEntry]
    let emptyMessage: String
    let open: (LibraryEntry) -> Void

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("No Projects", systemImage: "film.stack", description: Text(emptyMessage))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 20)], spacing: 20) {
                    ForEach(entries) { entry in
                        ProjectCard(entry: entry, open: { open(entry) })
                    }
                }
                .padding(24)
            }
        }
    }
}
