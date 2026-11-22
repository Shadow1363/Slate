import Foundation
import Observation

/// A project the home screen knows about. Slate remembers the folder by
/// bookmark, so it follows the folder when it's moved in Finder.
public struct LibraryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var bookmark: Data
    /// True if `bookmark` was made with `.withSecurityScope`.
    public var securityScoped: Bool
    public var lastKnownPath: String
    public var pinned: Bool
    public var added: Date
    public var lastOpened: Date?

    public var lastKnownURL: URL { URL(filePath: lastKnownPath, directoryHint: .isDirectory) }
    public var folderName: String { lastKnownURL.lastPathComponent }
}

public enum LibraryLocation: Equatable, Sendable {
    case found(URL)
    /// The bookmark can't be resolved, the folder is in the Trash, or it no
    /// longer has a `project.json`.
    case missing
}

public enum LibraryError: Error, Equatable, LocalizedError {
    case notAProject(String)

    public var errorDescription: String? {
        switch self {
        case .notAProject(let path): "\(path) isn't a Slate project: it has no project.json."
        }
    }
}

/// The home screen's list of projects, stored in `library.json` in Slate's
/// Application Support folder. Removing an entry never touches the files.
@MainActor
@Observable
public final class ProjectLibrary {
    public private(set) var entries: [LibraryEntry] = []
    /// Folders scanned for projects on launch.
    public private(set) var watchedFolders: [URL]
    /// Entries whose folder couldn't be found at the last `refreshStatuses()`.
    public private(set) var missing: Set<UUID> = []
    public private(set) var lastError: String?

    @ObservationIgnored private let fileURL: URL
    /// Paths removed by the user, so scanning a watched folder doesn't re-add them.
    @ObservationIgnored private var ignoredPaths: Set<String> = []

    private struct Stored: Codable {
        var version = 1
        var entries: [LibraryEntry]
        var watchedFolders: [String]
        var ignoredPaths: [String]
    }

    public init(directory: URL, defaultWatchedFolder: URL) {
        fileURL = directory.appending(path: "library.json")
        watchedFolders = [defaultWatchedFolder]
        load()
    }

    public var recent: [LibraryEntry] {
        entries.filter { $0.lastOpened != nil }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            .prefix(10)
            .map { $0 }
    }

    public var pinned: [LibraryEntry] {
        entries.filter(\.pinned)
    }

    public func entries(inWatchedFolder folder: URL) -> [LibraryEntry] {
        let folderPath = folder.standardizedFileURL.path
        return entries.filter { $0.lastKnownURL.deletingLastPathComponent().standardizedFileURL.path == folderPath }
    }

    // MARK: - Changes

    /// Adds a project folder, or returns its existing entry.
    @discardableResult
    public func add(_ folder: URL) throws -> LibraryEntry {
        guard ProjectScanner.isProject(folder) else { throw LibraryError.notAProject(folder.path) }
        let path = folder.standardizedFileURL.path
        ignoredPaths.remove(path)
        if let existing = entries.first(where: { $0.lastKnownPath == path }) {
            missing.remove(existing.id)
            return existing
        }
        let (bookmark, scoped) = try Self.makeBookmark(folder)
        let entry = LibraryEntry(
            id: UUID(), bookmark: bookmark, securityScoped: scoped, lastKnownPath: path,
            pinned: false, added: .now, lastOpened: nil
        )
        entries.append(entry)
        save()
        return entry
    }

    /// Forgets a project. Its folder stays where it is.
    public func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        ignoredPaths.insert(entries[index].lastKnownPath)
        entries.remove(at: index)
        missing.remove(id)
        save()
    }

    public func setPinned(_ pinned: Bool, for id: UUID) {
        update(id) { $0.pinned = pinned }
    }

    public func markOpened(_ id: UUID, at date: Date = .now) {
        update(id) { $0.lastOpened = date }
    }

    /// Points a missing entry at a folder the user picked.
    public func relocate(_ id: UUID, to folder: URL) throws {
        guard ProjectScanner.isProject(folder) else { throw LibraryError.notAProject(folder.path) }
        let (bookmark, scoped) = try Self.makeBookmark(folder)
        update(id) {
            $0.bookmark = bookmark
            $0.securityScoped = scoped
            $0.lastKnownPath = folder.standardizedFileURL.path
        }
        missing.remove(id)
    }

    /// Adds any projects found in the watched folders that aren't in the
    /// library yet (and weren't removed by the user).
    public func scanWatchedFolders() {
        let known = Set(entries.map(\.lastKnownPath))
        for folder in watchedFolders {
            for project in ProjectScanner.projects(in: folder) {
                let path = project.standardizedFileURL.path
                guard !known.contains(path), !ignoredPaths.contains(path) else { continue }
                _ = try? add(project)
            }
        }
    }

    // MARK: - Resolving

    /// Finds an entry's folder now, following moves. Refreshes the stored
    /// bookmark and path when the folder moved.
    public func resolve(_ id: UUID) -> LibraryLocation {
        guard let entry = entries.first(where: { $0.id == id }) else { return .missing }
        guard let url = resolvedURL(for: entry) else {
            missing.insert(id)
            return .missing
        }
        missing.remove(id)
        return .found(url)
    }

    public func refreshStatuses() {
        for entry in entries { _ = resolve(entry.id) }
    }

    private func resolvedURL(for entry: LibraryEntry) -> URL? {
        var stale = false
        var options: URL.BookmarkResolutionOptions = [.withoutUI]
        if entry.securityScoped { options.insert(.withSecurityScope) }

        var url = try? URL(resolvingBookmarkData: entry.bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        if url == nil || !Self.isLive(url!) {
            // The bookmark failed, but the folder may still be at its old path
            // (e.g. replaced by a copy from a backup).
            url = Self.isLive(entry.lastKnownURL) ? entry.lastKnownURL : nil
            stale = true
        }
        guard let url else { return nil }

        if entry.securityScoped {
            // A no-op while unsandboxed; required once Slate is sandboxed.
            _ = url.startAccessingSecurityScopedResource()
        }
        let path = url.standardizedFileURL.path
        if stale || path != entry.lastKnownPath, let (bookmark, scoped) = try? Self.makeBookmark(url) {
            update(entry.id) {
                $0.bookmark = bookmark
                $0.securityScoped = scoped
                $0.lastKnownPath = path
            }
        }
        return url
    }

    private static func isLive(_ url: URL) -> Bool {
        !url.standardizedFileURL.path.contains("/.Trash/") && ProjectScanner.isProject(url)
    }

    /// Prefers a security-scoped bookmark (needed if Slate is ever sandboxed),
    /// falling back to a plain one where that isn't allowed.
    static func makeBookmark(_ url: URL) throws -> (Data, Bool) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return (data, true)
        }
        return (try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), false)
    }

    // MARK: - Storage

    private func update(_ id: UUID, _ change: (inout LibraryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        change(&entry)
        if entry != entries[index] {
            entries[index] = entry
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let stored = try SlateJSON.decode(Stored.self, from: data)
            entries = stored.entries
            if !stored.watchedFolders.isEmpty {
                watchedFolders = stored.watchedFolders.map { URL(filePath: $0, directoryHint: .isDirectory) }
            }
            ignoredPaths = Set(stored.ignoredPaths)
        } catch {
            lastError = "Couldn't read the project library: \(SlateJSON.describe(error))"
        }
    }

    private func save() {
        let stored = Stored(
            entries: entries,
            watchedFolders: watchedFolders.map { $0.standardizedFileURL.path },
            ignoredPaths: ignoredPaths.sorted()
        )
        do {
            try CoordinatedFileIO.write(try SlateJSON.encode(stored), to: fileURL)
            lastError = nil
        } catch {
            lastError = "Couldn't save the project library: \(error.localizedDescription)"
        }
    }
}
