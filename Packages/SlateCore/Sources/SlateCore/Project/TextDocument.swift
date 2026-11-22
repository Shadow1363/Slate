import Foundation
import Observation

/// An open text file. Views bind to `text`; `ProjectStore` does all file I/O.
@MainActor
@Observable
public final class TextDocument: Identifiable {
    public enum DiskState: Equatable, Sendable {
        /// The file matches `lastKnownDisk`.
        case inSync
        /// Someone else changed the file while this buffer had unsaved edits.
        case changedOnDisk(String)
        /// The file was deleted, moved or renamed outside Slate.
        case deletedOnDisk
    }

    /// Path relative to the project root.
    public nonisolated let relativePath: String
    public nonisolated var id: String { relativePath }

    public var text: String {
        didSet {
            if text != oldValue { store?.documentDidChange(self) }
        }
    }

    /// The file's contents as Slate last read or wrote them.
    public internal(set) var lastKnownDisk: String
    public internal(set) var diskState: DiskState = .inSync
    public internal(set) var lastError: String?

    public var isDirty: Bool { text != lastKnownDisk }

    public var name: String { (relativePath as NSString).lastPathComponent }

    @ObservationIgnored weak var store: ProjectStore?
    @ObservationIgnored var autosaveTask: Task<Void, Never>?

    init(relativePath: String, text: String, store: ProjectStore) {
        self.relativePath = relativePath
        self.text = text
        self.lastKnownDisk = text
        self.store = store
    }
}
