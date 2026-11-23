import AppKit
import Observation
import SlateCore
import SlateExport
import SlateVoice
import SwiftUI
import UniformTypeIdentifiers

/// App-wide state shared by every window: the project library and themes.
@MainActor
@Observable
public final class SlateAppModel {
    public let library: ProjectLibrary
    public let themes: ThemeEngine
    public let updater = Updater()
    /// Set by File › New Project… so the home window shows the sheet.
    public var showingNewProject = false
    /// The welcome window has opened this launch.
    public var welcomeShown = false

    // MARK: Reminders state

    /// Open to-dos per project, for Home › Pending.
    private(set) var pending: [ProjectTodos] = []
    private(set) var pendingLoaded = false
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var startedReminders = false
    /// "Go to scene" requests for project windows, by project path.
    private(set) var jumpRequests: [String: JumpRequest] = [:]
    @ObservationIgnored private var sessions: [String: WeakSession] = [:]
    @ObservationIgnored private var scheduler: ReminderScheduler?
    @ObservationIgnored private var rescheduleTasks: [String: Task<Void, Never>] = [:]

    struct JumpRequest: Equatable {
        let sceneID: String?
        let quote: String?
        /// A file and range to show instead (a `TODO:` comment in a note).
        var path: String? = nil
        var range: NSRange? = nil
        let token = UUID()
    }

    private final class WeakSession {
        weak var session: ProjectSession?
        init(_ session: ProjectSession) { self.session = session }
    }

    public static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: "Slate", directoryHint: .isDirectory)
    }

    /// `~/Documents/Slate`: where new projects go and the default watched folder.
    public static var defaultProjectsFolder: URL {
        URL.documentsDirectory.appending(path: "Slate", directoryHint: .isDirectory)
    }

    public init() {
        SlateFonts.register()
        defer {
            updater.saveAll = { [weak self] in self?.saveAllProjects() }
        }
        let support = Self.applicationSupport
        library = ProjectLibrary(directory: support, defaultWatchedFolder: Self.defaultProjectsFolder)
        themes = ThemeEngine(userThemesDirectory: support.appending(path: "Themes", directoryHint: .isDirectory))
        // The notification centre needs an app bundle; tests run without one.
        if Bundle.main.bundleURL.pathExtension == "app" {
            let scheduler = ReminderScheduler()
            scheduler.onOpen = { [weak self] root, scene, path, location in
                if let path, let location {
                    self?.requestJump(to: root, path: path, range: NSRange(location: location, length: 0))
                } else {
                    self?.requestJump(to: root, sceneID: scene, quote: nil)
                }
            }
            self.scheduler = scheduler
        }
        // ggml's Metal backend aborts at exit if a Whisper model is still loaded.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            WhisperTranscriber.shared.unload()
        }
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
    /// File › Import…: a project folder or `.zip`, a screenplay, or a folder of Markdown notes.
    /// Returns the project to open.
    public func importProject() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = (ProjectImport.screenplayExtensions.union(["zip"])).compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.prompt = "Import"
        panel.message = "Choose a Slate project (folder or .zip), a screenplay (Fountain, Final Draft, text, Markdown), or a folder of Markdown notes such as an Obsidian vault."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return importProject(at: url)
    }

    public func importProject(at url: URL) -> URL? {
        let parent = Self.defaultProjectsFolder
        do {
            let root: URL
            switch ProjectImport.kind(of: url) {
            case .slateFolder:
                let alert = NSAlert()
                alert.messageText = "Add “\(url.lastPathComponent)” to the library?"
                alert.informativeText = "Add it where it is, or copy it into \(parent.path(percentEncoded: false))."
                alert.addButton(withTitle: "Add in Place")
                alert.addButton(withTitle: "Copy")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: root = url
                case .alertSecondButtonReturn: root = try ProjectImport.copyProject(url, into: parent)
                default: return nil
                }
            case .zip: root = try ProjectImport.importZip(url, into: parent)
            case .markdownFolder: root = try ProjectImport.importMarkdownFolder(url, into: parent)
            case .screenplay: root = try Publisher.createProject(from: url, in: parent)
            case nil: throw ProjectImport.ImportError.unsupported(url.lastPathComponent)
            }
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

    // MARK: - Open projects and jumps

    static func key(_ root: URL) -> String { root.standardizedFileURL.path }

    /// Saves every open project (before an update restarts Slate).
    public func saveAllProjects() {
        for weak in sessions.values { weak.session?.store.saveAll() }
    }

    func register(_ session: ProjectSession) {
        sessions[Self.key(session.store.rootURL)] = WeakSession(session)
    }

    func unregister(_ session: ProjectSession) {
        sessions[Self.key(session.store.rootURL)] = nil
    }

    func openSession(for root: URL) -> ProjectSession? {
        sessions[Self.key(root)]?.session
    }

    /// Asks the project's window (once open) to show a scene. The caller
    /// opens the window; a notification click is handled by `pendingOpen`.
    func requestJump(to root: URL, sceneID: String?, quote: String?) {
        jumpRequests[Self.key(root)] = JumpRequest(sceneID: sceneID, quote: quote)
        pendingOpen = root
    }

    /// Asks the project's window to show a range of a file (a note's `TODO:` comment).
    func requestJump(to root: URL, path: String, range: NSRange) {
        jumpRequests[Self.key(root)] = JumpRequest(sceneID: nil, quote: nil, path: path, range: range)
        pendingOpen = root
    }

    /// Opens a pending to-do where it was written: its scene, or the note at the comment.
    func requestJump(to root: URL, for item: PendingTodo) {
        switch item.kind {
        case .margin(let todo):
            requestJump(to: root, sceneID: todo.sceneID, quote: todo.quote)
        case .comment(let todo):
            if todo.path.hasPrefix(ProjectLayout.script + "/"), let scene = todo.sceneID {
                requestJump(to: root, sceneID: scene, quote: nil)
                jumpRequests[Self.key(root)] = JumpRequest(sceneID: scene, quote: nil, path: todo.path, range: todo.range)
            } else {
                requestJump(to: root, path: todo.path, range: todo.range)
            }
        }
    }

    /// A project the next active window should open (from a notification).
    var pendingOpen: URL?

    func takeJump(for root: URL) -> JumpRequest? {
        jumpRequests.removeValue(forKey: Self.key(root))
    }

    // MARK: - Launch reminders

    static func projectName(at root: URL) -> String {
        (try? CoordinatedFileIO.read(root.appending(path: ProjectLayout.manifest)))
            .flatMap { try? ProjectManifest.decode($0) }?.name ?? root.lastPathComponent
    }

    /// Projects in the library that can be found, newest-opened first.
    func reachableProjects() -> [(name: String, root: URL)] {
        library.recent.compactMap { entry in
            guard case .found(let url) = library.resolve(entry.id) else { return nil }
            return (Self.projectName(at: url), url)
        } + library.entries.filter { $0.lastOpened == nil }.compactMap { entry in
            guard case .found(let url) = library.resolve(entry.id) else { return nil }
            return (Self.projectName(at: url), url)
        }
    }

    /// Once per launch: schedule due-date notifications for every project.
    func startReminders() {
        guard !startedReminders else { return }
        startedReminders = true
        rescheduleAll()
    }

    /// Re-reads every project's open to-dos for Home › Pending, off the main thread.
    func refreshPending() {
        pendingTask?.cancel()
        let projects = reachableProjects()
        pendingTask = Task { [weak self] in
            let list = await Task.detached(priority: .utility) { Reminders.pending(projects: projects) }.value
            guard !Task.isCancelled, let self else { return }
            self.pending = list
            self.pendingLoaded = true
        }
    }

    /// Ticks a pending to-do: through the open window's documents if the
    /// project is open, else straight to the file.
    func complete(_ item: PendingTodo, in root: URL) {
        switch item.kind {
        case .margin(let todo):
            if let session = openSession(for: root) {
                session.script.margin.toggle(todo)
            } else {
                edit(root.appending(path: MarginTodos.path)) { MarginTodos.toggling(todo, in: $0) }
            }
        case .comment(let todo):
            if let session = openSession(for: root), let document = try? session.store.document(at: todo.path) {
                if let updated = CommentTodos.toggling(todo, in: document.text) {
                    document.text = updated
                } else {
                    Self.showError("Couldn't update the to-do", CocoaError(.fileWriteUnknown, userInfo: [
                        NSLocalizedDescriptionKey: "The comment changed since the list was made. The list has been refreshed."]))
                }
            } else {
                edit(root.appending(path: todo.path)) { CommentTodos.toggling(todo, in: $0) }
            }
        }
        pending = pending.compactMap { project in
            guard project.root == root else { return project }
            let rest = project.todos.filter { $0.id != item.id }
            return rest.isEmpty ? nil : ProjectTodos(name: project.name, root: project.root, todos: rest)
        }
        reschedule(root: root)
    }

    private func edit(_ url: URL, _ change: (String) -> String?) {
        do {
            let text = try CoordinatedFileIO.readText(url)
            guard let updated = change(text) else {
                refreshPending()
                return
            }
            try CoordinatedFileIO.writeText(updated, to: url)
        } catch {
            Self.showError("Couldn't update the to-do", error)
        }
    }

    // MARK: - Notifications

    var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: ReminderPreferences.notifications) as? Bool ?? true
    }

    /// Re-plans one project's due-date notifications (debounced).
    func reschedule(root: URL) {
        guard let scheduler else { return }
        let key = Self.key(root)
        rescheduleTasks[key]?.cancel()
        let enabled = notificationsEnabled
        rescheduleTasks[key] = Task { [weak self] in
            // Long enough for autosave to have written what was typed.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            let name = Self.projectName(at: root)
            let plan = enabled
                ? await Task.detached(priority: .utility) {
                    Reminders.plan(projectName: name, projectRoot: root, pending: Reminders.pending(in: root))
                }.value
                : []
            await scheduler.schedule(plan, for: root)
            self?.rescheduleTasks[key] = nil
        }
    }

    func rescheduleAll() {
        guard let scheduler else { return }
        guard notificationsEnabled else {
            Task { await scheduler.removeAll() }
            return
        }
        for project in reachableProjects() { reschedule(root: project.root) }
    }
}

public enum ReminderPreferences {
    public static let notifications = "dueDateNotifications"
}

extension SlateAppModel {
    /// A fresh copy of the sample film (Tidewater) in the projects folder, added to the library.
    public func makeSampleProject(in parent: URL = SlateAppModel.defaultProjectsFolder, sample: URL? = nil) -> URL? {
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let title = ProjectFolders.freeFolder(for: "Tidewater", in: parent).lastPathComponent
            let root = try ProjectCreator.create(title: title, template: .showcase, in: parent, sample: sample ?? ProjectCreator.bundledShowcase)
            let entry = try library.add(root)
            library.markOpened(entry.id)
            return root
        } catch {
            Self.showError("Couldn't make the sample film", error)
            return nil
        }
    }
}
