import AppKit
import SlateCore
import SwiftUI

enum HomeSection: Hashable {
    case all
    case recent
    case pinned
    case pending
    case watched(URL)
}

/// The project library: every project folder Slate knows about.
public struct HomeView: View {
    @Environment(SlateAppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var section: HomeSection? = .all
    @State private var search = ""
    @AppStorage("home.listView") private var listView = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $section) {
                Section("Library") {
                    Label("All Projects", systemImage: "square.grid.2x2").tag(HomeSection.all)
                    Label("Recent", systemImage: "clock").tag(HomeSection.recent)
                    Label("Pinned", systemImage: "pin").tag(HomeSection.pinned)
                    PendingSidebarRow().tag(HomeSection.pending)
                }
                Section {
                    ForEach(model.library.watchedFolders, id: \.self) { folder in
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .help(folder.path)
                            .tag(HomeSection.watched(folder))
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                                Button("Stop Watching") {
                                    if section == .watched(folder) { section = .all }
                                    model.library.removeWatchedFolder(folder)
                                }
                            }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Watched Folders")
                        Button {
                            LibraryActions.chooseWatchedFolder(model: model)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Watch another folder for projects")
                        .accessibilityLabel("Add Watched Folder")
                        Spacer()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if section == .pending {
                PendingView(search: search)
            } else {
                ProjectGrid(entries: visibleEntries, emptyMessage: emptyMessage, listView: listView, open: open)
            }
        }
        .navigationTitle(title)
        .searchable(text: $search, placement: .toolbar, prompt: section == .pending ? "Search to-dos" : "Search projects")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: $listView) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(false)
                    Label("List", systemImage: "list.bullet").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Show projects as cards or a list")
            }
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
                Button {
                    if let url = model.importProject() { openWindow(id: SlateWindowID.project, value: url) }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import a project folder or .zip, a screenplay, or a folder of Markdown notes (⇧⌘I)")
            }
        }
        .sheet(isPresented: $model.showingNewProject) {
            NewProjectSheet { url in openWindow(id: SlateWindowID.project, value: url) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { UpdateBanner() }
        .task {
            #if DEBUG
            if ScreenshotTour.folder != nil {
                model.welcomeShown = true
                ScreenshotTour.start(model: model) { openWindow(id: SlateWindowID.project, value: $0) }
                return
            }
            #endif
            if UserDefaults.standard.object(forKey: WelcomePreferences.showAtLaunch) as? Bool ?? true, !model.welcomeShown {
                model.welcomeShown = true
                openWindow(id: SlateWindowID.welcome)
            }
            model.library.scanWatchedFolders()
            model.library.refreshStatuses()
            model.startReminders()
            model.refreshPending()
            model.updater.checkAtLaunch()
        }
        .onChange(of: model.pendingOpen) { _, root in
            // A due-date notification was clicked.
            guard let root else { return }
            model.pendingOpen = nil
            openWindow(id: SlateWindowID.project, value: root)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.library.refreshStatuses()
            model.refreshPending()
        }
        .frame(minWidth: 720, minHeight: 440)
        .slateThemed()
    }

    private var title: String {
        switch section ?? .all {
        case .all: "All Projects"
        case .recent: "Recent"
        case .pinned: "Pinned"
        case .pending: "Pending"
        case .watched(let folder): folder.lastPathComponent
        }
    }

    private var visibleEntries: [LibraryEntry] {
        let entries: [LibraryEntry] = switch section ?? .all {
        case .all: model.library.entries.sorted { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
        case .recent: model.library.recent
        case .pinned: model.library.pinned
        case .pending: []
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
        case .pending: ""
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
    public static let themes = "themes"
    public static let welcome = "welcome"
}

struct ProjectGrid: View {
    let entries: [LibraryEntry]
    let emptyMessage: String
    var listView = false
    let open: (LibraryEntry) -> Void

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("No Projects", systemImage: "film.stack", description: Text(emptyMessage))
        } else if listView {
            ProjectList(entries: entries, open: open)
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

/// Library › Pending, with the number of open to-dos (red when some are overdue).
private struct PendingSidebarRow: View {
    @Environment(SlateAppModel.self) private var model

    var body: some View {
        let all = model.pending.flatMap(\.todos)
        let overdue = all.contains { $0.todo.isOverdue() }
        Label("Pending", systemImage: "checklist")
            .badge(all.isEmpty ? nil : Text("\(all.count)").foregroundStyle(overdue ? .red : .secondary))
            .help(overdue ? "Open to-dos, some overdue" : "Open to-dos in every project")
    }
}
