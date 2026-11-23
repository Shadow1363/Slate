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

    public init(model: SlateAppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.updater.check(userInitiated: true) }
        }
        CommandGroup(replacing: .newItem) {
            // ⌘N makes a note inside a project window, a project elsewhere.
            if actions != nil {
                Button(actions?.newItemTitle ?? "New Note…") { actions?.newNote() }
                    .keyboardShortcut("n")
                Button("New Project…") {
                    openWindow(id: SlateWindowID.home)
                    model.showingNewProject = true
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
            } else {
                Button("New Project…") {
                    openWindow(id: SlateWindowID.home)
                    model.showingNewProject = true
                }
                .keyboardShortcut("n")
            }
            Button("Open Folder…") {
                if let url = model.chooseProjectFolder() {
                    openWindow(id: SlateWindowID.project, value: url)
                }
            }
            .keyboardShortcut("o")
            Button("Import…") {
                if let url = model.importProject() {
                    openWindow(id: SlateWindowID.project, value: url)
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Project Library") {
                openWindow(id: SlateWindowID.home)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { actions?.save() }
                .keyboardShortcut("s")
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .printItem) {
            // Print stays on ⌥⌘P, where it has always been in Slate.
            Button("Print Script…") { actions?.printScript() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
        CommandMenu("Script") {
            Button("Toggle Page View") { actions?.togglePageView() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Menu("Publish") {
                Button("PDF") { actions?.publish(.pdf) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
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
                        .keyboardShortcut("]", modifiers: [.command, .control])
                        .disabled(actions.films.count < 2)
                    Button("Previous Film") { actions.script(.previousFilm) }
                        .keyboardShortcut("[", modifiers: [.command, .control])
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
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Snapshots…") { actions?.script(.showSnapshots) }
                .disabled(actions == nil)
            Divider()
            Button("Add To-do…") { actions?.addTodo() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Add Margin Note…") { actions?.addMarginNote() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Show All To-dos") { actions?.showAllTodos() }
                .disabled(actions == nil)
            Button("Toggle Margin") { actions?.toggleMargin() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button("Jump to Scene…") { actions?.jumpToScene() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button("Move Scene Up") { actions?.moveScene(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(actions == nil)
            Button("Move Scene Down") { actions?.moveScene(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(actions == nil)
        }
        CommandMenu("Storyboard") {
            Button("Watch Animatic") { actions?.watchAnimatic() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("New Sketch…") { actions?.newSketch() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
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
            let shortcut = SearchShortcut(searchShortcut) ?? SearchShortcut(SearchPreferences.defaultShortcut)!
            Button("Search…") { actions?.search("") }
                .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                .disabled(actions == nil)
            Button("Search Text…") { actions?.search("!text ") }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Insert Link") {
                NSApp.sendAction(#selector(SlateTextView.insertWikiLink(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            Button("Define Selection") { actions?.defineSelection() }
                .keyboardShortcut("d", modifiers: [.command, .option, .control])
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
                    .keyboardShortcut(KeyEquivalent(Character(String(area.shortcutNumber))), modifiers: .command)
                    .disabled(actions == nil)
            }
            Button("Toggle Inspector") { actions?.toggleInspector() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(actions == nil)
            Toggle("Focus Mode", isOn: Binding(get: { actions?.focusMode ?? false }, set: { _ in actions?.script(.toggleFocus) }))
                .keyboardShortcut(.return, modifiers: [.command, .shift])
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
