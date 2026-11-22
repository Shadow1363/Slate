import AppKit
import Observation
import SlateCore
import SlateExport
import SwiftUI
import UniformTypeIdentifiers

/// App-wide state shared by every window: the project library and themes.
@MainActor
@Observable
public final class SlateAppModel {
    public let library: ProjectLibrary
    public let themes: ThemeEngine
    /// Set by File › New Project… so the home window shows the sheet.
    public var showingNewProject = false

    public static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: "Slate", directoryHint: .isDirectory)
    }

    /// `~/Documents/Slate`: where new projects go and the default watched folder.
    public static var defaultProjectsFolder: URL {
        URL.documentsDirectory.appending(path: "Slate", directoryHint: .isDirectory)
    }

    public init() {
        SlateFonts.register()
        let support = Self.applicationSupport
        library = ProjectLibrary(directory: support, defaultWatchedFolder: Self.defaultProjectsFolder)
        themes = ThemeEngine(userThemesDirectory: support.appending(path: "Themes", directoryHint: .isDirectory))
    }

    /// Asks for a project folder and adds it to the library. Returns the
    /// folder to open, or nil if cancelled or not a project.
    public func chooseProjectFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Slate project folder (one with a project.json inside)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let entry = try library.add(url)
            library.markOpened(entry.id)
            return url
        } catch {
            Self.showError("Can't open this folder", error)
            return nil
        }
    }

    /// Asks for a Fountain, Final Draft, text or Markdown screenplay, makes a
    /// new project from it in `~/Documents/Slate`, and returns the project folder.
    public func importScreenplay() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["fountain", "fdx", "txt", "md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Import"
        panel.message = "Choose a screenplay: Fountain, Final Draft (.fdx), plain text or Markdown."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let root = try Publisher.createProject(from: url, in: Self.defaultProjectsFolder)
            let entry = try library.add(root)
            library.markOpened(entry.id)
            return root
        } catch {
            Self.showError("Couldn't import “\(url.lastPathComponent)”", error)
            return nil
        }
    }

    /// Resolves a library entry and records the open. Returns nil if missing.
    public func prepareToOpen(_ entry: LibraryEntry) -> URL? {
        guard case .found(let url) = library.resolve(entry.id) else { return nil }
        library.markOpened(entry.id)
        return url
    }

    public static func showError(_ title: String, _ error: any Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
