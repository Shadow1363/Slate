import AppKit
import SlateCore
import SwiftUI
import UniformTypeIdentifiers

/// The project card's file actions: rename, duplicate, zip, trash.
@MainActor
enum LibraryActions {
    static func rename(_ entry: LibraryEntry, current name: String, model: SlateAppModel) {
        guard !isOpen(entry, model: model) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Project"
        alert.informativeText = "The project's folder is renamed to match."
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let moved = try ProjectFolders.rename(entry.lastKnownURL, to: field.stringValue)
            model.library.moved(entry.id, to: moved)
        } catch {
            SlateAppModel.showError("Couldn't rename the project", error)
        }
    }

    static func duplicate(_ entry: LibraryEntry, model: SlateAppModel) {
        do {
            let copy = try ProjectFolders.duplicate(entry.lastKnownURL)
            try model.library.add(copy)
        } catch {
            SlateAppModel.showError("Couldn't duplicate the project", error)
        }
    }

    static func exportZip(_ entry: LibraryEntry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = entry.folderName + ".zip"
        panel.message = "The project folder, without its cache and exports."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectFolders.zip(entry.lastKnownURL, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            SlateAppModel.showError("Couldn't make the .zip", error)
        }
    }

    static func moveToTrash(_ entry: LibraryEntry, name: String, model: SlateAppModel) {
        guard !isOpen(entry, model: model) else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(name)” to the Trash?"
        alert.informativeText = "The whole project folder goes to the Trash. You can put it back from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: entry.lastKnownURL, resultingItemURL: nil)
            model.library.remove(entry.id)
        } catch {
            SlateAppModel.showError("Couldn't move the project to the Trash", error)
        }
    }

    /// Renaming or trashing an open project would pull the folder out from under its window.
    private static func isOpen(_ entry: LibraryEntry, model: SlateAppModel) -> Bool {
        guard model.openSession(for: entry.lastKnownURL) != nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Close the project first"
        alert.informativeText = "“\(entry.folderName)” is open in a window."
        alert.runModal()
        return true
    }

    static func chooseWatchedFolder(model: SlateAppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        panel.message = "Slate lists every project in this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.library.addWatchedFolder(url)
    }
}
