/// What to do with an open document when its file may have changed on disk.
public enum ExternalChange: Equatable, Sendable {
    /// Disk matches what we last read or wrote. Nothing to do.
    case unchanged
    /// The buffer has no unsaved edits (or already equals the new disk
    /// text), so take the disk version.
    case reload(String)
    /// The buffer has unsaved edits and the disk changed too. Ask the user.
    case conflict(String)
    /// The file is gone. Keep the buffer and ask the user.
    case deletedOnDisk
}

/// Decides how an outside edit meets an open document. Pure, so every case is unit-tested.
public enum ExternalChangeResolver {
    /// - Parameters:
    ///   - buffer: The text in the editor right now.
    ///   - lastKnownDisk: The file's contents when Slate last read or wrote it.
    ///   - newDisk: The file's contents now, or nil if it no longer exists.
    public static func resolve(buffer: String, lastKnownDisk: String, newDisk: String?) -> ExternalChange {
        guard let newDisk else { return .deletedOnDisk }
        if newDisk == lastKnownDisk { return .unchanged }
        if buffer == newDisk || buffer == lastKnownDisk { return .reload(newDisk) }
        return .conflict(newDisk)
    }
}
