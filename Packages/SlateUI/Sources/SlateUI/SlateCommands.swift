import SlateCore
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
