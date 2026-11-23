import AppKit
import SlateCore

/// Sagas: several films in one project, one folder each in `script/`.
extension ScriptWorkspace {
    // MARK: Reading

    /// Re-parses the films that aren't open (open buffers win over disk).
    func refreshOtherFilms() {
        let paths = scriptPaths
        let outlines = films.filter { $0.folder != film.folder }.map { other in
            FilmOutline(film: other, parsed: Films.actFiles(paths: paths, in: other).map { path in
                let text = store.documents[path]?.text ?? (try? store.readText(at: path)) ?? ""
                return parse(text, path: path)
            })
        }
        if outlines != otherFilms { setOtherFilms(outlines) }
    }

    /// Every scene with an ID, film by film.
    var sagaScenes: [(film: Film, id: String, heading: String)] {
        let current = film
        return films.flatMap { item -> [(film: Film, id: String, heading: String)] in
            if item.folder == current.folder {
                return book.scenes.compactMap { scene in scene.scene.sceneID.map { (item, $0, scene.scene.heading) } }
            }
            return otherFilms.first { $0.film.folder == item.folder }?.scenes.map { (item, $0.id, $0.heading) } ?? []
        }
    }

    /// The film a scene ID is in.
    func film(containingScene id: String) -> Film? {
        if book.scenes.contains(where: { $0.scene.sceneID == id }) { return film }
        return otherFilms.first { $0.scenes.contains { $0.id == id } }?.film
    }

    // MARK: Switching

    /// Opens another film in the Script and Storyboard areas.
    func select(film target: Film) {
        guard target.folder != filmFolder else { return }
        store.saveAll()
        setFilmFolder(target.folder)
        currentFile = nil
        showingTitlePage = false
        caret = nil
        selectedRow = nil
        lastRevealedRow = nil
        frameHighlight = nil
        reveal = nil
        showingSides = false
        showingSnapshots = false
        refreshFiles()
    }

    /// The film after or before this one (⌃⌘] and ⌃⌘[).
    func selectAdjacentFilm(_ delta: Int) {
        let films = films
        guard let index = films.firstIndex(where: { $0.folder == film.folder }), films.indices.contains(index + delta) else { return }
        select(film: films[index + delta])
    }

    // MARK: New, rename, trash

    /// Adds a film. The first time, the project's own script moves into
    /// `script/01 <project name>/` so every film has a folder of its own.
    @discardableResult
    func newFilm(title: String, date: Date = .now) throws -> Film {
        store.saveAll()
        if films.count == 1, film.isRoot { try makeSaga() }
        let existing = films.filter { !$0.isRoot }
        let numbers = existing.compactMap { Int($0.folderName.prefix { $0.isNumber }) }
        let number = (numbers.max() ?? existing.count) + 1
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Film \(number)" }
        let new = Film(folder: ProjectLayout.script + "/" + Films.folderName(number: number, title: name),
                       title: Films.title(fromFolderName: Films.folderName(number: number, title: name)))
        guard !films.contains(where: { $0.folder.lowercased() == new.folder.lowercased() }) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: new.folder])
        }
        for (path, text) in Films.starterFiles(for: new, date: date).sorted(by: { $0.key < $1.key }) {
            _ = try store.createTextFile(at: path, contents: text)
        }
        store.rescan()
        select(film: new)
        return new
    }

    /// Moves the single film's files from `script/` into `script/01 <name>/`.
    func makeSaga() throws {
        let snapshots = store.rootURL.appending(path: ScriptSnapshot.folder)
        let hidden = FileManager.default.fileExists(atPath: snapshots.path) ? [".snapshots"] : []
        let plan = Films.sagaMoves(paths: scriptPaths, projectName: store.manifest.name, hiddenFolders: hidden)
        try FileManager.default.createDirectory(at: try store.url(for: plan.film.folder), withIntermediateDirectories: true)
        for move in plan.moves {
            closeDocuments(inside: move.from)
            try store.moveFile(from: move.from, to: move.to)
        }
        if currentFile.map({ Films.isActFile($0) && !$0.dropFirst(ProjectLayout.script.count + 1).contains("/") }) == true {
            currentFile = currentFile.map { plan.film.path(($0 as NSString).lastPathComponent) }
        }
        setFilmFolder(plan.film.folder)
        store.rescan()
        // Canvas cards that pointed at the old act files follow them.
        for canvas in (store.files[.universe] ?? []) where canvas.name.lowercased().hasSuffix(".canvas") {
            guard let document = try? store.document(at: canvas.relativePath) else { continue }
            let moved = Films.rewritingPaths(in: document.text, moves: plan.moves)
            if moved != document.text {
                document.text = moved
                store.save(document)
            }
        }
        refreshFiles()
    }

    /// Renames a film's folder, keeping its number.
    func rename(film target: Film, to title: String) throws {
        guard !target.isRoot else { return }
        let number = Int(target.folderName.prefix { $0.isNumber }) ?? ((films.firstIndex(of: target) ?? 0) + 1)
        let folder = ProjectLayout.script + "/" + Films.folderName(number: number, title: title)
        guard folder != target.folder else { return }
        store.saveAll()
        closeDocuments(inside: target.folder)
        try store.moveFile(from: target.folder, to: folder)
        if filmFolder == target.folder {
            setFilmFolder(folder)
            currentFile = currentFile.map { folder + $0.dropFirst(target.folder.count) }
        }
        store.rescan()
        refreshFiles()
    }

    /// Moves a film's folder to the Trash. Its boards stay, and are tidied into
    /// `storyboard/orphans/` like any board whose scene is gone.
    func trash(film target: Film) throws {
        guard !target.isRoot, films.count > 1 else { return }
        store.saveAll()
        if filmFolder == target.folder, let next = films.first(where: { $0.folder != target.folder }) { select(film: next) }
        closeDocuments(inside: target.folder)
        try store.trashFile(target.folder)
        store.rescan()
        refreshFiles()
    }

    private func closeDocuments(inside folder: String) {
        for (path, document) in store.documents where path == folder || path.hasPrefix(folder + "/") {
            store.closeDocument(document)
        }
    }

    // MARK: Prompts

    func promptForNewFilm() {
        let first = films.count == 1 && film.isRoot
        let message = first
            ? "Each film gets its own folder in script/. This script moves into “script/\(Films.folderName(number: 1, title: store.manifest.name))/”; storyboards, notes and to-dos stay where they are."
            : "A new film with its own title page and act files. Storyboards, notes and the dictionary are shared by every film."
        guard let title = askForTitle("New Film", message: message, value: "", placeholder: "The Return", button: "Create") else { return }
        do {
            try newFilm(title: title)
        } catch {
            SlateAppModel.showError("Couldn't create the film", error)
        }
    }

    func promptForRename() {
        let target = film
        guard !target.isRoot,
              let title = askForTitle("Rename Film", message: "Renames the folder \(target.folder)/; its number stays.", value: target.title,
                                      placeholder: target.title, button: "Rename") else { return }
        do {
            try rename(film: target, to: title)
        } catch {
            SlateAppModel.showError("Couldn't rename the film", error)
        }
    }

    func confirmTrashFilm() {
        let target = film
        guard !target.isRoot, films.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(target.title)” to the Trash?"
        alert.informativeText = "Its folder \(target.folder)/ goes to the Trash. Its storyboard frames move to storyboard/orphans/ when the project closes."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try trash(film: target)
        } catch {
            SlateAppModel.showError("Couldn't move the film to the Trash", error)
        }
    }

    private func askForTitle(_ title: String, message: String, value: String, placeholder: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
