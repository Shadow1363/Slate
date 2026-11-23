import AppKit
import SlateCore
import SlateExport

/// What the Production menu can do.
public enum ProductionCommand: Sendable {
    case lockScenes, unlockScenes, lockPages, unlockPages, startRevision, clearRevisions
    case report(ProductionReport, csv: Bool)
    case sides
}

/// Production mode: locked scene numbers and pages, revisions, reports and sides.
/// Everything lives in `script/production.json` and `script/revisions/`.
extension ScriptWorkspace {
    // MARK: Reading

    /// Re-reads production.json and the current revision's baseline.
    func refreshProduction() {
        let path = ProductionFile.path
        let exists = store.files[.script]?.contains { $0.relativePath == path } == true
        let text = store.documents[path]?.text ?? (exists ? (try? store.readText(at: path)) : nil) ?? ""
        let file = (try? ProductionFile(text: text)) ?? ProductionFile()
        var newBaseline: [(name: String, text: String)]?
        if let folder = file.currentBaselineFolder {
            newBaseline = (store.files[.script] ?? [])
                .filter { ($0.relativePath as NSString).deletingLastPathComponent == folder }
                .sorted { $0.name < $1.name }
                .compactMap { item in (try? store.readText(at: item.relativePath)).map { (name: item.name, text: $0) } }
        }
        let baselineChanged = newBaseline.map { $0.map { $0.name + "\u{0}" + $0.text } } != baseline.map { $0.map { $0.name + "\u{0}" + $0.text } }
        if file != production || baselineChanged {
            production = file
            baseline = newBaseline
            productionVersion += 1
        }
    }

    func productionLayout(_ parsed: [ParsedScript], names: [String]) -> ProductionLayout? {
        guard !production.isEmpty else { return nil }
        return ProductionLayout.make(files: zip(names, parsed).map { (name: $0, parsed: $1) }, production: production, baseline: baseline)
    }

    /// Scene labels in script order: locked numbers (`14A`) or positions.
    var sceneLabels: [String] { book.scenes.map(\.label) }

    /// One line for the navigator: `Locked · Blue Rev. 11/23/26`.
    var productionStatus: String? {
        var parts: [String] = []
        if production.scenesLocked { parts.append(production.pagesLocked ? "Scenes and pages locked" : "Scenes locked") }
        else if production.pagesLocked { parts.append("Pages locked") }
        if let revision = production.currentRevision { parts.append("\(revision.color.rawValue) Rev. \(revision.date)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Writing

    func updateProduction(_ change: (inout ProductionFile) -> Void) {
        var file = production
        change(&file)
        guard file != production else { return }
        let path = ProductionFile.path
        do {
            if let document = try store.documents[path] ?? (store.files[.script]?.contains { $0.relativePath == path } == true ? store.document(at: path) : nil) {
                document.text = file.text
                store.save(document)
            } else {
                _ = try store.createTextFile(at: path, contents: file.text)
            }
        } catch {
            SlateAppModel.showError("Couldn't save production.json", error)
        }
        store.rescan()
        refreshProduction()
    }

    // MARK: Commands

    func perform(_ command: ProductionCommand) {
        switch command {
        case .lockScenes: lockScenes()
        case .unlockScenes:
            if confirm("Unlock scene numbers?", "Scenes will be numbered 1, 2, 3… again, and cut scenes will no longer print as OMITTED.") {
                updateProduction { $0.scenes = nil }
            }
        case .lockPages: lockPages()
        case .unlockPages:
            if confirm("Unlock pages?", "Pages will flow freely again and A-pages will be renumbered.") {
                updateProduction { $0.pages = nil }
            }
        case .startRevision: startRevision()
        case .clearRevisions:
            if confirm("Clear all revisions?", "Revision marks and colours are removed. The baseline copies in script/revisions/ go to the Trash.") {
                clearRevisions()
            }
        case .report(let report, let csv): exportReport(report, csv: csv)
        case .sides: showingSides = true
        }
    }

    /// Locks the current numbers. Scenes already locked keep theirs; new ones keep their letters.
    func lockScenes() {
        store.saveAll()
        let scenes = SceneNumbering.scenes(in: book.files.map(\.parsed))
        updateProduction { $0.scenes = SceneNumbering.lock(scenes, existing: $0.scenes) }
    }

    /// Records where every page starts now.
    func lockPages() {
        store.saveAll()
        let source = scriptSource()
        let parsed = source.parsed
        var layout = source.productionLayout(parsed) ?? ProductionLayout()
        layout.pages = nil
        let paginated = Paginator(settings: publishSettings, production: layout).paginate(parsed)
        updateProduction { $0.pages = PageAnchors.make(from: paginated, files: parsed) }
    }

    /// Starts the next colour: copies today's script into `script/revisions/NN colour/`
    /// as the baseline that later changes are marked against.
    func startRevision(date: Date = .now) {
        store.saveAll()
        let color = production.nextColor
        let folder = ProductionFile.baselineFolder(index: production.revisions.count, color: color)
        do {
            for file in scriptFiles {
                let text = try store.documents[file.relativePath]?.text ?? store.readText(at: file.relativePath)
                let url = try store.url(for: folder + "/" + file.name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try CoordinatedFileIO.write(Data(text.utf8), to: url)
            }
        } catch {
            SlateAppModel.showError("Couldn't start the revision", error)
            return
        }
        store.rescan()
        let day = date.formatted(.iso8601.year().month().day())
        updateProduction { $0.revisions.append(ScriptRevision(color: color, date: day)) }
    }

    func clearRevisions() {
        if store.files[.script]?.contains(where: { $0.relativePath.hasPrefix(ProductionFile.revisionsFolder + "/") }) == true {
            do {
                try store.trashFile(ProductionFile.revisionsFolder)
            } catch {
                SlateAppModel.showError("Couldn't move the revisions to the Trash", error)
                return
            }
        }
        store.rescan()
        updateProduction { $0.revisions = [] }
    }

    // MARK: Exports

    @discardableResult
    func writeReport(_ report: ProductionReport, csv: Bool) throws -> URL {
        store.saveAll()
        let url = try Publisher.exportReport(report, csv: csv, scriptSource(), projectRoot: store.rootURL)
        store.rescan()
        return url
    }

    func exportReport(_ report: ProductionReport, csv: Bool) {
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try writeReport(report, csv: csv)])
        } catch {
            SlateAppModel.showError("Couldn't export the report", error)
        }
    }

    @discardableResult
    func writeSides(sceneIDs: Set<String>) throws -> URL {
        store.saveAll()
        let url = try Publisher.exportSides(sceneIDs: sceneIDs, scriptSource(), projectRoot: store.rootURL)
        store.rescan()
        return url
    }

    private func confirm(_ title: String, _ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
