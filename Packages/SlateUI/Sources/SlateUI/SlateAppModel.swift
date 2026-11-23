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

    /// Open to-dos per project, for the sheet shown at launch.
    var launchReminders: [ProjectTodos] = []
    var showingLaunchReminders = false
    @ObservationIgnored private var checkedLaunchReminders = false
    /// "Go to scene" requests for project windows, by project path.
    private(set) var jumpRequests: [String: JumpRequest] = [:]
    @ObservationIgnored private var sessions: [String: WeakSession] = [:]
    @ObservationIgnored private var scheduler: ReminderScheduler?
    @ObservationIgnored private var rescheduleTasks: [String: Task<Void, Never>] = [:]

    struct JumpRequest: Equatable {
        let sceneID: String?
        let quote: String?
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
            scheduler.onOpen = { [weak self] root, scene in self?.requestJump(to: root, sceneID: scene, quote: nil) }
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

    /// Once per launch: collect open to-dos for the sheet, per the setting.
    func checkLaunchReminders() {
        guard !checkedLaunchReminders else { return }
        checkedLaunchReminders = true
        let scope = LaunchReminderScope(rawValue: UserDefaults.standard.string(forKey: ReminderPreferences.launchScope) ?? "") ?? .lastProject
        let projects: [(name: String, root: URL)]
        switch scope {
        case .off: projects = []
        case .lastProject: projects = Array(reachableProjects().prefix(1))
        case .allProjects: projects = reachableProjects()
        }
        launchReminders = Reminders.launchList(projects: projects)
        showingLaunchReminders = !launchReminders.isEmpty
        rescheduleAll()
    }

    /// Ticks a to-do from the launch sheet: through the open window's
    /// document if the project is open, else straight to the file.
    func complete(_ todo: MarginTodo, in root: URL) {
        if let session = openSession(for: root) {
            session.script.margin.toggle(todo)
        } else {
            let url = root.appending(path: MarginTodos.path)
            do {
                let text = try CoordinatedFileIO.readText(url)
                guard let updated = MarginTodos.toggling(todo, in: text) else { return }
                try CoordinatedFileIO.writeText(updated, to: url)
            } catch {
                Self.showError("Couldn't update the to-do", error)
            }
        }
        launchReminders = launchReminders.compactMap { project in
            guard project.root == root else { return project }
            let rest = project.todos.filter { $0.id != todo.id }
            return rest.isEmpty ? nil : ProjectTodos(name: project.name, root: project.root, todos: rest)
        }
        reschedule(root: root)
    }

    // MARK: - Notifications

    var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: ReminderPreferences.notifications) as? Bool ?? true
    }

    /// Re-plans one project's due-date notifications (debounced).
    func reschedule(root: URL, todos: [MarginTodo]? = nil) {
        guard let scheduler else { return }
        let key = Self.key(root)
        rescheduleTasks[key]?.cancel()
        let enabled = notificationsEnabled
        rescheduleTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let list = todos ?? Reminders.todos(in: root)
            let plan = enabled ? Reminders.plan(projectName: Self.projectName(at: root), projectRoot: root, todos: list) : []
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
    public static let launchScope = "launchReminderScope"
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
