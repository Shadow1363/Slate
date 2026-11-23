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
/// Before changing anything it copies the original manifest, and any script
/// file it rewrites, to `.slate/backups/`.
///
/// - 1 → 2: Slate switched to standard Fountain. In schema 1 a `#` line was a
///   scene heading; now it's a section. Each such line in the act files
///   becomes a plain heading (`INT. KITCHEN - NIGHT {#s014}`) when Fountain
///   recognises it, or a forced one (`.THE VAULT {#s015}`) when not.
/// - 2 → 3: the dictionary became one book, `dictionary/words.md`. The words
///   in `dictionary/words.txt` become spelling entries; each
///   `dictionary/terms/*.md` moves to `universe/notes/` and gets an entry
///   with its definition and a link to it.
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

        if manifest.schemaVersion < 2 {
            try migrateHashHeadings(projectRoot: projectRoot, backupFolder: "script-v\(manifest.schemaVersion)-\(stamp)", presenter: presenter)
        }
        if manifest.schemaVersion < 3 {
            try migrateWordBook(projectRoot: projectRoot, backupFolder: "dictionary-v\(manifest.schemaVersion)-\(stamp)", presenter: presenter)
        }

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

    // MARK: - 1 → 2

    private static func migrateHashHeadings(projectRoot: URL, backupFolder: String, presenter: (any NSFilePresenter)?) throws {
        for url in Films.onDisk(root: projectRoot).flatMap(\.files) {
            let name = String(url.path.dropFirst(projectRoot.appending(path: ProjectLayout.script).path.count + 1))
            guard let text = try? CoordinatedFileIO.readText(url, presenter: presenter) else { continue }
            let converted = fountainHeadings(from: text)
            guard converted != text else { continue }
            let backup = projectRoot.appending(path: ProjectLayout.backups, directoryHint: .isDirectory)
                .appending(path: backupFolder, directoryHint: .isDirectory).appending(path: name)
            try CoordinatedFileIO.writeText(text, to: backup, presenter: presenter)
            try CoordinatedFileIO.writeText(converted, to: url, presenter: presenter)
        }
    }

    /// Schema 1 → 2 for one act file: `# HEADING` lines become Fountain headings.
    static func fountainHeadings(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var inBoneyard = false
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBoneyard {
                if line.contains("*/") { inBoneyard = false }
                continue
            }
            if trimmed.hasPrefix("/*") {
                if !trimmed.dropFirst(2).contains("*/") { inBoneyard = true }
                continue
            }
            guard trimmed.hasPrefix("#") else { continue }
            let body = String(trimmed.drop { $0 == "#" }.drop { $0 == " " || $0 == "\t" })
            let afterBlank = index == 0 || lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty
            let carriageReturn = body.hasSuffix("\r") ? "\r" : ""
            let clean = carriageReturn.isEmpty ? body : String(body.dropLast())
            if afterBlank, ScriptParser.isHeading(clean) {
                lines[index] = clean + carriageReturn
            } else {
                lines[index] = "." + clean + carriageReturn
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 2 → 3

    private static func migrateWordBook(projectRoot: URL, backupFolder: String, presenter: (any NSFilePresenter)?) throws {
        let dictionary = projectRoot.appending(path: ProjectLayout.dictionary, directoryHint: .isDirectory)
        let backup = projectRoot.appending(path: ProjectLayout.backups, directoryHint: .isDirectory)
            .appending(path: backupFolder, directoryHint: .isDirectory)
        let bookURL = projectRoot.appending(path: WordBook.path)
        let wordsURL = dictionary.appending(path: "words.txt")
        let termsURL = dictionary.appending(path: "terms", directoryHint: .isDirectory)
        let fm = FileManager.default

        let oldWords = (try? CoordinatedFileIO.readText(wordsURL, presenter: presenter))
        let termNames = ((try? fm.contentsOfDirectory(atPath: termsURL.path)) ?? [])
            .filter { ($0 as NSString).pathExtension.lowercased() == "md" }
            .sorted()
        let hadBook = fm.fileExists(atPath: bookURL.path)
        guard oldWords != nil || !termNames.isEmpty || !hadBook else { return }

        var book = hadBook ? ((try? CoordinatedFileIO.readText(bookURL, presenter: presenter)) ?? "") : WordBook.starter
        var known = Set(WordBook.parse(book).map { WordBook.fold($0.word) })

        // Term files first, so a word that's also in words.txt keeps its definition.
        let notes = projectRoot.appending(path: "universe/notes", directoryHint: .isDirectory)
        for name in termNames {
            let url = termsURL.appending(path: name)
            guard let text = try? CoordinatedFileIO.readText(url, presenter: presenter) else { continue }
            try CoordinatedFileIO.writeText(text, to: backup.appending(path: "terms").appending(path: name), presenter: presenter)
            let note = Note(path: "dictionary/terms/" + name, text: text)
            let word = note.value("word")?.text.nilIfEmpty ?? note.name
            var destination = notes.appending(path: name)
            var counter = 2
            while fm.fileExists(atPath: destination.path) {
                destination = notes.appending(path: "\((name as NSString).deletingPathExtension)-\(counter).md")
                counter += 1
            }
            try fm.createDirectory(at: notes, withIntermediateDirectories: true)
            try CoordinatedFileIO.move(url, to: destination, presenter: presenter)
            guard !known.contains(WordBook.fold(word)) else { continue }
            known.insert(WordBook.fold(word))
            let definition = (note.value("definition")?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The file name resolves too, so a term without `name:` links by its word.
            let target = (note.value("name") ?? note.value("title"))?.text.nilIfEmpty ?? word
            let link = "See " + WikiLink.text(for: target) + "."
            let entry = WordEntry(
                word: word,
                part: (note.value("part") ?? note.value("partOfSpeech") ?? note.value("part of speech"))?.text.nilIfEmpty,
                forms: (note.value("forms") ?? note.value("plural"))?.items ?? [],
                explanation: definition.isEmpty ? link : definition + (definition.hasSuffix(".") ? " " : ". ") + link
            )
            book = WordBook.adding(entry, to: book)
        }
        if let oldWords {
            try CoordinatedFileIO.writeText(oldWords, to: backup.appending(path: "words.txt"), presenter: presenter)
            for word in WordBook.parse(oldWords).map(\.word) where !known.contains(WordBook.fold(word)) {
                known.insert(WordBook.fold(word))
                book = WordBook.adding(WordEntry(word: word), to: book)
            }
        }
        try CoordinatedFileIO.writeText(book, to: bookURL, presenter: presenter)
        if oldWords != nil { try? fm.removeItem(at: wordsURL) }
        if ((try? fm.contentsOfDirectory(atPath: termsURL.path)) ?? ["x"]).filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: termsURL)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
