import Foundation

public enum MigrationError: Error, Equatable, LocalizedError {
    case newerSchema(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .newerSchema(let found, let supported):
            "This project was saved by a newer version of Slate (schema \(found); this version reads up to \(supported)). Update Slate to open it."
        }
    }
}

/// Brings an older `project.json` up to `ProjectManifest.currentSchemaVersion`.
///
/// Before changing anything it copies the original manifest to
/// `.slate/backups/`. No real migrations exist yet (schema 1 is the first),
/// so an older file only gets its version number bumped.
public enum ProjectMigrator {
    /// One step per version: `migrations[n]` upgrades a manifest from n to n + 1.
    static let migrations: [Int: @Sendable (inout ProjectManifest) -> Void] = [:]

    /// Returns the migrated manifest, writing it and a backup if anything changed.
    public static func migrateIfNeeded(
        _ manifest: ProjectManifest,
        originalData: Data,
        projectRoot: URL,
        presenter: (any NSFilePresenter)? = nil,
        now: Date = .now
    ) throws -> ProjectManifest {
        let current = ProjectManifest.currentSchemaVersion
        if manifest.schemaVersion > current {
            throw MigrationError.newerSchema(found: manifest.schemaVersion, supported: current)
        }
        guard manifest.schemaVersion < current else { return manifest }

        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let backup = projectRoot
            .appending(path: ProjectLayout.backups, directoryHint: .isDirectory)
            .appending(path: "project-v\(manifest.schemaVersion)-\(stamp).json")
        try CoordinatedFileIO.write(originalData, to: backup, presenter: presenter)

        var migrated = manifest
        while migrated.schemaVersion < current {
            migrations[migrated.schemaVersion]?(&migrated)
            migrated.schemaVersion += 1
        }
        try CoordinatedFileIO.write(
            try migrated.encoded(),
            to: projectRoot.appending(path: ProjectLayout.manifest),
            presenter: presenter
        )
        return migrated
    }
}
