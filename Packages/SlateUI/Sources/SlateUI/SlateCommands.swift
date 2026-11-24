import AppKit
import SlateCore
import SlateExport
import SwiftUI

/// Menu bar commands: File › New / Open / Save and View › area shortcuts.
public struct SlateCommands: Commands {
    let model: SlateAppModel
    @FocusedValue(\.projectActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SearchPreferences.shortcut) private var searchShortcut = SearchPreferences.defaultShortcut
    @AppStorage(Shortcuts.overridesKey) private var shortcutOverrides = ""

    public init(model: SlateAppModel) {
        self.model = model
    }

    public var body: some Commands {
        // Settings › Shortcuts can change any of these.
        let key = ShortcutLookup(overridesJSON: shortcutOverrides, search: searchShortcut)
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.updater.check(userInitiated: true) }
                .keyboardShortcut(key("checkForUpdates"))
        }
        CommandGroup(replacing: .newItem) {
            // ⌘N makes a note inside a project window, a project elsewhere.
            if actions != nil {
                Button(actions?.newItemTitle ?? "New Note…") { actions?.newNote() }
                    .keyboardShortcut(key("newNote"))
                Button("New Project…") {
                    openWindow(id: SlateWindowID.home)
                    model.showingNewProject = true
                }
                .keyboardShortcut(key("newProject"))
            } else {
                Button("New Project…") {
                    openWindow(id: SlateWindowID.home)
                    model.showingNewProject = true
                }
                .keyboardShortcut(key("newNote"))
            }
            Button("Open Folder…") {
                if let url = model.chooseProjectFolder() {
                    openWindow(id: SlateWindowID.project, value: url)
                }
            }
            .keyboardShortcut(key("openFolder"))
            Button("Import Voice Note…") { actions?.importVoiceNote() }
                .keyboardShortcut(key("importVoiceNote"))
                .disabled(actions == nil)
            Button("Import…") {
                if let url = model.importProject() {
                    openWindow(id: SlateWindowID.project, value: url)
                }
            }
            .keyboardShortcut(key("import"))
            Divider()
            Button("Project Library") {
                openWindow(id: SlateWindowID.home)
            }
            .keyboardShortcut(key("projectLibrary"))
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { actions?.save() }
                .keyboardShortcut(key("save"))
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .printItem) {
            // Print stays on ⌥⌘P, where it has always been in Slate.
            Button("Print Script…") { actions?.printScript() }
                .keyboardShortcut(key("printScript"))
                .disabled(actions == nil)
        }
        CommandMenu("Script") {
            Button("Toggle Page View") { actions?.togglePageView() }
                .keyboardShortcut(key("togglePageView"))
                .disabled(actions == nil)
            Menu("Publish") {
                Button("PDF") { actions?.publish(.pdf) }
                    .keyboardShortcut(key("publishPDF"))
                ForEach(ExportFormat.allCases.filter { $0.isScript && $0 != .pdf }) { format in
                    Button(format.title) { actions?.publish(format) }
                }
                Divider()
                Button(ExportFormat.animatic.title) { actions?.publish(.animatic) }
                Button(ExportFormat.boards.title) { actions?.publish(.boards) }
            }
            .disabled(actions == nil)
            Menu("Production") {
                if let actions {
                    ProductionMenuItems(production: actions.productionFile) { command in actions.production(command) }
                }
            }
            .disabled(actions == nil)
            Divider()
            Button("New Act File") { actions?.script(.newActFile) }
                .disabled(actions == nil)
            Menu("Film") {
                if let actions {
                    ForEach(Array(actions.films.enumerated()), id: \.element.folder) { index, film in
                        Toggle("\(index + 1). \(film.title)", isOn: Binding(
                            get: { actions.currentFilm == film.folder },
                            set: { _ in actions.script(.selectFilm(film.folder)) }
                        ))
                    }
                    Divider()
                    Button("Next Film") { actions.script(.nextFilm) }
                        .keyboardShortcut(key("nextFilm"))
                        .disabled(actions.films.count < 2)
                    Button("Previous Film") { actions.script(.previousFilm) }
                        .keyboardShortcut(key("previousFilm"))
                        .disabled(actions.films.count < 2)
                    Divider()
                    Button("New Film…") { actions.script(.newFilm) }
                    Button("Rename Film…") { actions.script(.renameFilm) }
                        .disabled(actions.films.first { $0.folder == actions.currentFilm }?.isRoot ?? true)
                    Button("Move Film to Trash…") { actions.script(.trashFilm) }
                        .disabled(actions.films.count < 2 || (actions.films.first { $0.folder == actions.currentFilm }?.isRoot ?? true))
                }
            }
            .disabled(actions == nil)
            Button("Save Snapshot…") { actions?.script(.saveSnapshot) }
                .keyboardShortcut(key("saveSnapshot"))
                .disabled(actions == nil)
            Button("Snapshots…") { actions?.script(.showSnapshots) }
                .disabled(actions == nil)
            Divider()
            Button("Add To-do…") { actions?.addTodo() }
                .keyboardShortcut(key("addTodo"))
                .disabled(actions == nil)
            Button("Add Margin Note…") { actions?.addMarginNote() }
                .keyboardShortcut(key("addMarginNote"))
                .disabled(actions == nil)
            Button("Show All To-dos") { actions?.showAllTodos() }
                .disabled(actions == nil)
            Divider()
            Button("Jump to Scene…") { actions?.jumpToScene() }
                .keyboardShortcut(key("jumpToScene"))
                .disabled(actions == nil)
            Divider()
            Button("Move Scene Up") { actions?.moveScene(-1) }
                .keyboardShortcut(key("moveSceneUp"))
                .disabled(actions == nil)
            Button("Move Scene Down") { actions?.moveScene(1) }
                .keyboardShortcut(key("moveSceneDown"))
                .disabled(actions == nil)
        }
        CommandMenu("Storyboard") {
            Button("Watch Animatic") { actions?.watchAnimatic() }
                .keyboardShortcut(key("watchAnimatic"))
                .disabled(actions == nil)
            Button("New Sketch…") { actions?.newSketch() }
                .keyboardShortcut(key("newSketch"))
                .disabled(actions == nil)
            Divider()
            Button("Export Animatic (.mov)") { actions?.publish(.animatic) }
                .disabled(actions == nil)
            Menu("Export Boards PDF") {
                ForEach(BoardsPDF.Layout.allCases) { layout in
                    Button(layout.title) { actions?.exportBoards(layout) }
                }
            }
            .disabled(actions == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            FindMenu(target: actions?.findTarget, focusFilter: { actions?.focusFilter() })
            Button("Search…") { actions?.search("") }
                .keyboardShortcut(key(Shortcuts.search) ?? KeyboardShortcut("k"))
                .disabled(actions == nil)
            Button("Search Text…") { actions?.search("!text ") }
                .keyboardShortcut(key("searchText"))
                .disabled(actions == nil)
            Button("Insert Link") {
                NSApp.sendAction(#selector(SlateTextView.insertWikiLink(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(key("insertLink"))
            Button("Dictate") {
                NSApp.sendAction(#selector(SlateTextView.toggleSlateDictation(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(key("dictate"))
            Button("Define Selection") { actions?.defineSelection() }
                .keyboardShortcut(key("defineSelection"))
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Slate") { openWindow(id: SlateWindowID.welcome) }
            Button("Open Sample Film") {
                if let root = model.makeSampleProject() { openWindow(id: SlateWindowID.project, value: root) }
            }
        }
        CommandGroup(before: .sidebar) {
            ForEach(ProjectArea.allCases) { area in
                Button(area.title) { actions?.selectArea(area) }
                    .keyboardShortcut(key("area." + area.rawValue))
                    .disabled(actions == nil)
            }
            Button("Toggle Sidebar") { actions?.toggleInspector() }
                .keyboardShortcut(key("toggleInspector"))
                .disabled(actions == nil)
            Button("Show To-dos") { actions?.toggleMargin() }
                .keyboardShortcut(key("toggleMargin"))
                .disabled(actions == nil)
            Toggle("Focus Mode", isOn: Binding(get: { actions?.focusMode ?? false }, set: { _ in actions?.script(.toggleFocus) }))
                .keyboardShortcut(key("focusMode"))
                .disabled(actions == nil)
            Toggle("Typewriter Scrolling", isOn: Binding(get: { actions?.typewriter ?? false }, set: { _ in actions?.script(.toggleTypewriter) }))
                .disabled(actions == nil)
            Menu("Theme for This Project") {
                Picker("Theme for This Project", selection: Binding(get: { actions?.projectTheme ?? "" },
                                                                    set: { actions?.setProjectTheme($0.isEmpty ? nil : $0) })) {
                    Text("Use Settings").tag("")
                    Divider()
                    ForEach(model.themes.themes) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(actions == nil)
            Divider()
        }
    }
}

/// Edit › Find: the native find bar in the open text file. Where a view has
/// no text (storyboard, dictionary, canvas), Find… focuses its filter instead.
private struct FindMenu: View {
    let target: ProjectSession.FindTarget?
    let focusFilter: @MainActor () -> Void

    var body: some View {
        Menu("Find") {
            Button("Find…") {
                if !(target == .editor && TextFinderRouter.perform(.showFindInterface)) { focusFilter() }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(target == nil)
            Group {
                Button("Find and Replace…") { TextFinderRouter.perform(.showReplaceInterface) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { TextFinderRouter.perform(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { TextFinderRouter.perform(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { TextFinderRouter.perform(.setSearchString) }
                    .keyboardShortcut("e", modifiers: .command)
            }
            .disabled(target != .editor)
        }
    }
}
