import Foundation

public enum FileIOError: Error, LocalizedError, Equatable {
    case notUTF8(String)

    public var errorDescription: String? {
        switch self {
        case .notUTF8(let name): "“\(name)” isn't UTF-8 text, so Slate won't open it as text."
        }
    }
}

/// All reads and writes of project files go through here.
///
/// Every access is coordinated with `NSFileCoordinator` (safe alongside iCloud
/// Drive and other apps), and every write is atomic: the data goes to a temp
/// file that then replaces the original, so a crash never leaves half a file.
public enum CoordinatedFileIO {
    public static func read(_ url: URL, presenter: (any NSFilePresenter)? = nil) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var result: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    public static func write(_ data: Data, to url: URL, presenter: (any NSFilePresenter)? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var result: Result<Void, any Error> = .success(())
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { url in
            result = Result { try data.write(to: url, options: [.atomic]) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    public static func readText(_ url: URL, presenter: (any NSFilePresenter)? = nil) throws -> String {
        let data = try read(url, presenter: presenter)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FileIOError.notUTF8(url.lastPathComponent)
        }
        return text
    }

    public static func writeText(_ text: String, to url: URL, presenter: (any NSFilePresenter)? = nil) throws {
        try write(Data(text.utf8), to: url, presenter: presenter)
    }

    /// Moves a file, coordinated for both places. Fails if `destination` exists.
    public static func move(_ source: URL, to destination: URL, presenter: (any NSFilePresenter)? = nil) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var result: Result<Void, any Error> = .success(())
        coordinator.coordinate(writingItemAt: source, options: [.forMoving], writingItemAt: destination, options: [.forReplacing], error: &coordinationError) { from, to in
            result = Result {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Moves a file to the Trash (never deletes it outright).
    /// Moves an item to the Trash and returns where it went there.
    @discardableResult
    public static func trash(_ url: URL, presenter: (any NSFilePresenter)? = nil) throws -> URL? {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var result: Result<URL?, any Error> = .success(nil)
        coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordinationError) { url in
            result = Result {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                return trashed as URL?
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
