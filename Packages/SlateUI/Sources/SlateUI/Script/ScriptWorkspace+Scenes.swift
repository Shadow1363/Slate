import AppKit
import SlateCore

/// What the Script menu sends to the workspace.
public enum ScriptCommand: Sendable {
    case newActFile, saveSnapshot, showSnapshots, toggleFocus, toggleTypewriter
    case newFilm, renameFilm, trashFilm, nextFilm, previousFilm
    /// A film's folder (`script/02 Slack Water`).
    case selectFilm(String)
}

/// Scene labels, moving scenes between act files, new act files, snapshots.
extension ScriptWorkspace {
    func perform(_ command: ScriptCommand) {
        switch command {
        case .newActFile: newActFile()
        case .saveSnapshot: promptForSnapshot()
        case .showSnapshots: showingSnapshots = true
        case .toggleFocus: focusMode.toggle()
        case .toggleTypewriter: typewriter.toggle()
        case .newFilm: promptForNewFilm()
        case .renameFilm: promptForRename()
        case .trashFilm: confirmTrashFilm()
        case .nextFilm: selectAdjacentFilm(1)
        case .previousFilm: selectAdjacentFilm(-1)
        case .selectFilm(let folder):
            if let film = films.first(where: { $0.folder == folder }) { select(film: film) }
        }
    }

    // MARK: Colour labels

    /// Writes `color=` into the scene's tag (nil removes it).
    func setColor(_ color: SceneColor?, for scene: ScriptBook.Scene) {
        guard let document = store.documents[scene.file] else { return }
        let text = SceneEditing.settingAttribute("color", to: color?.rawValue, headingLine: scene.scene.headingLine, in: document.text)
        if text != document.text { document.text = text }
    }

    // MARK: Act files

    /// Moves a scene to another act file, before scene `index` there (the end when nil).
    func moveScene(_ scene: ScriptBook.Scene, toFile path: String, at index: Int? = nil) {
        guard path != scene.file, let source = store.documents[scene.file], let target = store.documents[path],
              let position = book.scenes.filter({ $0.file == scene.file }).firstIndex(where: { $0.id == scene.id }),
              let (rest, block) = SceneEditing.removingScene(position, from: source.text) else { return }
        let count = ScriptParser.parse(target.text).scenes.count
        target.text = SceneEditing.insertingScene(block, at: min(index ?? count, count), in: target.text)
        source.text = rest
    }

    /// `04-act-four.md`, starting with `# ACT FOUR`.
    func newActFile() {
        let names = Set(scriptFiles.map(\.name))
        let next = scriptFiles.compactMap { Int($0.name.prefix(2)) }.max().map { $0 + 1 } ?? (scriptFiles.count + 1)
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let word = next <= words.count ? words[next - 1] : String(next)
        var name = String(format: "%02d-act-%@.md", next, word)
        if names.contains(name) { name = String(format: "%02d-act-%@-2.md", next, word) }
        do {
            let document = try store.createTextFile(at: film.path(name), contents: "# ACT \(word.uppercased())\n\n")
            store.rescan()
            refreshFiles()
            show(file: document.relativePath)
        } catch {
            SlateAppModel.showError("Couldn't create the act file", error)
        }
    }

    /// A scene ID used in an earlier act file, or an earlier film, gets a new
    /// one (a file copied in Finder, or a paste). Later films count too, so the new ID is free everywhere.
    func repairDuplicateSceneIDs() {
        let files = scriptFiles.compactMap { store.documents[$0.relativePath] }
        let position = films.firstIndex { $0.folder == film.folder } ?? 0
        let order = Dictionary(films.enumerated().map { ($1.folder, $0) }, uniquingKeysWith: { a, _ in a })
        let before = otherFilms.filter { (order[$0.film.folder] ?? 0) < position }.flatMap(\.parsed)
        let after = otherFilms.filter { (order[$0.film.folder] ?? 0) > position }.flatMap(\.parsed)
        guard files.count + before.count > 1 else { return }
        let all = SceneEditing.crossFileDuplicates(in: before + files.map { ScriptParser.parse($0.text) } + after)
        let edits = all[before.count ..< before.count + files.count]
        for (document, fileEdits) in zip(files, edits) where !fileEdits.isEmpty {
            let text = NSMutableString(string: document.text)
            for edit in fileEdits.reversed() { text.replaceCharacters(in: edit.range, with: edit.replacement) }
            document.text = text as String
            store.save(document)
        }
    }

    // MARK: Snapshots

    var snapshots: [ScriptSnapshot] { ScriptSnapshot.all(in: store.rootURL, folder: film.snapshotsFolder) }

    /// The act files as they are now (open buffers win).
    var currentActTexts: [(name: String, text: String)] {
        scriptFiles.map { file in (file.name, store.documents[file.relativePath]?.text ?? ((try? store.readText(at: file.relativePath)) ?? "")) }
    }

    @discardableResult
    func saveSnapshot(name: String, date: Date = .now) throws -> ScriptSnapshot {
        try ScriptSnapshot.save(name: name, files: currentActTexts, in: store.rootURL, folder: film.snapshotsFolder, date: date)
    }

    /// ⇧⌘S: asks for a name, then saves.
    func promptForSnapshot() {
        let alert = NSAlert()
        alert.messageText = "Save Snapshot"
        alert.informativeText = "A copy of the script, kept in \(film.snapshotsFolder)/."
        let field = NSTextField(string: "")
        field.placeholderString = "Before the rewrite"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try saveSnapshot(name: field.stringValue)
        } catch {
            SlateAppModel.showError("Couldn't save the snapshot", error)
        }
    }

    /// Puts a snapshot's text back, after saving today's script as "Before restore".
    func restore(_ snapshot: ScriptSnapshot) throws {
        try saveSnapshot(name: "Before restore")
        let files = try snapshot.files()
        for file in files {
            let path = film.path(file.name)
            if let document = store.documents[path] ?? (try? store.document(at: path)) {
                document.text = file.text
                store.save(document)
            } else {
                _ = try store.createTextFile(at: path, contents: file.text)
            }
        }
        store.rescan()
        refreshFiles()
    }
}
