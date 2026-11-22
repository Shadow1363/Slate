import SlateCore
import SlateExport
import SwiftUI

/// Menu bar commands: File › New / Open / Save and View › area shortcuts.
public struct SlateCommands: Commands {
    let model: SlateAppModel
    @FocusedValue(\.projectActions) private var actions
    @Environment(\.openWindow) private var openWindow

    public init(model: SlateAppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") {
                openWindow(id: SlateWindowID.home)
                model.showingNewProject = true
            }
            .keyboardShortcut("n")
            Button("Open Folder…") {
                if let url = model.chooseProjectFolder() {
                    openWindow(id: SlateWindowID.project, value: url)
                }
            }
            .keyboardShortcut("o")
            Button("Import Screenplay…") {
                if let url = model.importScreenplay() {
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
            // ⌘P is Quick Open (Milestone 4), so Print uses ⌥⌘P.
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
                ForEach(ExportFormat.allCases.filter { $0.isAvailable && $0 != .pdf }) { format in
                    Button(format.title) { actions?.publish(format) }
                }
            }
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
        CommandGroup(before: .sidebar) {
            ForEach(ProjectArea.allCases) { area in
                Button(area.title) { actions?.selectArea(area) }
                    .keyboardShortcut(KeyEquivalent(Character(String(area.shortcutNumber))), modifiers: .command)
                    .disabled(actions == nil)
            }
            Divider()
        }
    }
}
