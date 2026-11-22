import Foundation
import Observation

public enum ProjectStoreError: Error, Equatable, LocalizedError {
    case notAProject(String)
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .notAProject(let path): "\(path) isn't a Slate project: it has no project.json."
        case .invalidPath(let path): "“\(path)” is outside the project."
        }
    }
}

/// One open project folder. The only code that reads or writes it.
///
/// Views observe `manifest`, `files` and open `TextDocument`s and send edits
/// back. Outside changes arrive from `FileWatcher`; each open document is then
/// checked with `ExternalChangeResolver`, so a clean document reloads and a
/// document with unsaved edits is flagged instead of overwritten.
@MainActor
@Observable
public final class ProjectStore {
    public let rootURL: URL
    public private(set) var manifest: ProjectManifest
    /// Files in each area folder, sorted by path. Hidden files are skipped.
    public private(set) var files: [ProjectArea: [ProjectFile]] = [:]
    public private(set) var documents: [String: TextDocument] = [:]
    /// Set when `project.json` was edited outside Slate into something unreadable.
    public private(set) var manifestError: String?

    private let watcher: FileWatcher
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private let autosaveDelay: Duration?
    @ObservationIgnored private var lastManifestData: Data

    /// Opens a project folder, migrating `project.json` if it is older.
    /// - Parameter autosaveDelay: Idle time before an edited document saves
    ///   itself, or nil to save only on `save(_:)`.
    public init(rootURL: URL, autosaveDelay: Duration? = .seconds(2)) throws {
        let manifestURL = rootURL.appending(path: ProjectLayout.manifest)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ProjectStoreError.notAProject(rootURL.path)
        }
        let watcher = FileWatcher(rootURL: rootURL)
        let data = try CoordinatedFileIO.read(manifestURL, presenter: watcher.filePresenter)
        let manifest = try ProjectMigrator.migrateIfNeeded(
            try ProjectManifest.decode(data),
            originalData: data,
            projectRoot: rootURL,
            presenter: watcher.filePresenter
        )

        self.rootURL = rootURL
        self.watcher = watcher
        self.manifest = manifest
        self.autosaveDelay = autosaveDelay
        self.lastManifestData = (try? CoordinatedFileIO.read(manifestURL, presenter: watcher.filePresenter)) ?? data
        rescan()
    }

    deinit {
        watcher.stop()
    }

    // MARK: - Watching

    /// Starts reacting to outside changes.
    public func startWatching() {
        guard watchTask == nil else { return }
        watcher.start()
        let events = watcher.events
        watchTask = Task { [weak self] in
            for await batch in events {
                self?.handleExternalChanges(batch)
            }
        }
    }

    /// Saves what can be saved safely and stops watching.
    public func close() {
        saveAll()
        watcher.stop()
        watchTask?.cancel()
        watchTask = nil
    }

    /// Re-reads the folder after outside changes. Called by the watcher; tests
    /// call it directly.
    public func handleExternalChanges(_ paths: Set<String> = [""]) {
        rescan()
        if paths.contains("") || paths.contains(ProjectLayout.manifest) {
            reloadManifestIfChanged()
        }
        for document in documents.values {
            checkDisk(document)
        }
    }

    // MARK: - Files

    public func url(for relativePath: String) throws -> URL {
        let url = rootURL.appending(path: relativePath).standardizedFileURL
        let root = rootURL.standardizedFileURL.path
        guard url.path.hasPrefix(root + "/") else { throw ProjectStoreError.invalidPath(relativePath) }
        return url
    }

    public func rescan() {
        let fm = FileManager.default
        var result: [ProjectArea: [ProjectFile]] = [:]
        for area in ProjectArea.allCases {
            let areaURL = rootURL.appending(path: area.folder, directoryHint: .isDirectory)
            var found: [ProjectFile] = []
            if let enumerator = fm.enumerator(at: areaURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    let relative = area.folder + "/" + relativeComponents(of: url, under: areaURL)
                    found.append(ProjectFile(relativePath: relative, area: area))
                }
            }
            found.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            result[area] = found
        }
        if result != files { files = result }
    }

    private func relativeComponents(of url: URL, under base: URL) -> String {
        let baseCount = base.standardizedFileURL.pathComponents.count
        return url.standardizedFileURL.pathComponents.dropFirst(baseCount).joined(separator: "/")
    }

    // MARK: - Documents

    /// Opens (or returns the already-open) document for a file.
    public func document(at relativePath: String) throws -> TextDocument {
        if let open = documents[relativePath] { return open }
        let text = try CoordinatedFileIO.readText(try url(for: relativePath), presenter: watcher.filePresenter)
        let document = TextDocument(relativePath: relativePath, text: text, store: self)
        documents[relativePath] = document
        return document
    }

    /// Reads a file's current text: the open buffer if there is one, else the disk.
    public func readText(at relativePath: String) throws -> String {
        if let open = documents[relativePath] { return open.text }
        return try CoordinatedFileIO.readText(try url(for: relativePath), presenter: watcher.filePresenter)
    }

    /// Creates a new text file. Fails if one already exists at that path.
    @discardableResult
    public func createTextFile(at relativePath: String, contents: String = "") throws -> TextDocument {
        let url = try url(for: relativePath)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        try CoordinatedFileIO.writeText(contents, to: url, presenter: watcher.filePresenter)
        rescan()
        return try document(at: relativePath)
    }

    /// Saves if possible and forgets the document.
    public func closeDocument(_ document: TextDocument) {
        if document.diskState == .inSync, document.isDirty { save(document) }
        document.autosaveTask?.cancel()
        documents[document.relativePath] = nil
    }

    /// Writes the buffer, unless the file changed on disk since it was read:
    /// then the document is flagged as a conflict instead.
    public func save(_ document: TextDocument) {
        document.autosaveTask?.cancel()
        guard document.diskState == .inSync, document.isDirty else { return }
        // Catch an outside edit the watcher hasn't reported yet.
        checkDisk(document)
        guard document.diskState == .inSync else { return }
        write(document)
    }

    public func saveAll() {
        for document in documents.values { save(document) }
    }

    /// Resolves a conflict or deletion by writing the buffer to disk.
    public func keepMine(_ document: TextDocument) {
        write(document)
    }

    /// Resolves a conflict by taking the disk version. For a deleted file,
    /// closes the document.
    public func loadTheirs(_ document: TextDocument) {
        switch document.diskState {
        case .changedOnDisk(let theirs):
            document.autosaveTask?.cancel()
            document.lastKnownDisk = theirs
            document.text = theirs
            document.diskState = .inSync
        case .deletedOnDisk:
            document.autosaveTask?.cancel()
            documents[document.relativePath] = nil
        case .inSync:
            break
        }
    }

    func documentDidChange(_ document: TextDocument) {
        document.autosaveTask?.cancel()
        guard let autosaveDelay, document.isDirty, document.diskState == .inSync else { return }
        document.autosaveTask = Task { [weak self, weak document] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled, let self, let document else { return }
            self.save(document)
        }
    }

    private func write(_ document: TextDocument) {
        document.autosaveTask?.cancel()
        do {
            let text = document.text
            try CoordinatedFileIO.writeText(text, to: try url(for: document.relativePath), presenter: watcher.filePresenter)
            document.lastKnownDisk = text
            document.diskState = .inSync
            document.lastError = nil
            rescan()
        } catch {
            document.lastError = error.localizedDescription
        }
    }

    private func checkDisk(_ document: TextDocument) {
        guard let url = try? url(for: document.relativePath) else { return }
        let newDisk: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                newDisk = try CoordinatedFileIO.readText(url, presenter: watcher.filePresenter)
            } catch {
                document.lastError = error.localizedDescription
                return
            }
        } else {
            newDisk = nil
        }

        switch ExternalChangeResolver.resolve(buffer: document.text, lastKnownDisk: document.lastKnownDisk, newDisk: newDisk) {
        case .unchanged:
            // The outside change was undone (or the file came back).
            if document.diskState != .inSync { document.diskState = .inSync }
        case .reload(let theirs):
            document.autosaveTask?.cancel()
            document.lastKnownDisk = theirs
            if document.text != theirs { document.text = theirs }
            document.diskState = .inSync
        case .conflict(let theirs):
            document.autosaveTask?.cancel()
            document.diskState = .changedOnDisk(theirs)
        case .deletedOnDisk:
            document.autosaveTask?.cancel()
            document.diskState = .deletedOnDisk
        }
    }

    // MARK: - Moving, trashing and multi-file edits

    /// Moves a file inside the project. An open document is saved first and
    /// reopened at its new path, which is returned.
    @discardableResult
    public func moveFile(from source: String, to destination: String) throws -> TextDocument? {
        let from = try url(for: source)
        let to = try url(for: destination)
        guard !FileManager.default.fileExists(atPath: to.path) || from.path.lowercased() == to.path.lowercased() else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to.path])
        }
        let open = documents[source]
        if let open {
            if open.isDirty, open.diskState == .inSync { write(open) }
            open.autosaveTask?.cancel()
            documents[source] = nil
        }
        try CoordinatedFileIO.move(from, to: to, presenter: watcher.filePresenter)
        rescan()
        guard let open else { return nil }
        let moved = try document(at: destination)
        // Keep edits that couldn't be saved (a conflict) in the new buffer.
        if moved.text != open.text { moved.text = open.text }
        return moved
    }

    /// Moves a file to the Trash and closes its document.
    public func trashFile(_ relativePath: String) throws {
        if let open = documents[relativePath] {
            open.autosaveTask?.cancel()
            documents[relativePath] = nil
        }
        try CoordinatedFileIO.trash(try url(for: relativePath), presenter: watcher.filePresenter)
        rescan()
    }

    /// Applies text edits across files: open documents change in memory (and
    /// autosave as usual), closed files are rewritten atomically. Each edit's
    /// `original` must still be at its range, or that file is left alone.
    /// Returns the paths that changed.
    @discardableResult
    public func applyEdits(_ edits: [FileEdit]) throws -> [String] {
        var changed: [String] = []
        for (path, fileEdits) in Dictionary(grouping: edits, by: \.path).sorted(by: { $0.key < $1.key }) {
            let text = try readText(at: path)
            guard let updated = FileEdit.apply(fileEdits, to: text), updated != text else { continue }
            if let open = documents[path] {
                open.text = updated
            } else {
                try CoordinatedFileIO.writeText(updated, to: try url(for: path), presenter: watcher.filePresenter)
            }
            changed.append(path)
        }
        if !changed.isEmpty { rescan() }
        return changed
    }

    // MARK: - Manifest

    /// Changes `project.json` (atomically, keeping unknown keys).
    public func updateManifest(_ change: (inout ProjectManifest) -> Void) throws {
        var updated = manifest
        change(&updated)
        guard updated != manifest else { return }
        let data = try updated.encoded()
        try CoordinatedFileIO.write(data, to: rootURL.appending(path: ProjectLayout.manifest), presenter: watcher.filePresenter)
        lastManifestData = data
        manifest = updated
    }

    private func reloadManifestIfChanged() {
        let manifestURL = rootURL.appending(path: ProjectLayout.manifest)
        guard let data = try? CoordinatedFileIO.read(manifestURL, presenter: watcher.filePresenter) else {
            manifestError = "project.json is missing. Restore it to keep this folder a Slate project."
            return
        }
        guard data != lastManifestData else { return }
        lastManifestData = data
        do {
            let updated = try ProjectManifest.decode(data)
            if updated.schemaVersion > ProjectManifest.currentSchemaVersion {
                throw MigrationError.newerSchema(found: updated.schemaVersion, supported: ProjectManifest.currentSchemaVersion)
            }
            if updated != manifest { manifest = updated }
            manifestError = nil
        } catch {
            manifestError = error.localizedDescription
        }
    }
}
