import AppKit
import Observation
import SlateCore
import UniformTypeIdentifiers

/// A frame, by its scene folder and file name.
struct FrameRef: Hashable, Sendable {
    let folder: String
    let file: String

    var path: String { folder + "/" + file }
    /// Drag payload.
    var payload: String { "slate-frame:" + folder + "|" + file }

    init(folder: String, file: String) {
        self.folder = folder
        self.file = file
    }

    init?(payload: String) {
        guard payload.hasPrefix("slate-frame:") else { return nil }
        let parts = payload.dropFirst("slate-frame:".count).split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        self.init(folder: String(parts[0]), file: String(parts[1]))
    }
}

/// The Storyboard area: one row per scene (in script order), each with the
/// frames in its folder. Edits write `frames.json` through the store, so
/// autosave and outside changes work as for any file.
@MainActor
@Observable
final class StoryboardModel {
    struct Row: Identifiable {
        enum Kind { case scene, missing, orphan }

        /// The scene ID, or the folder path for missing and orphaned boards.
        let id: String
        let kind: Kind
        let scene: ScriptBook.Scene?
        let folder: SceneFolder?
        let frames: [StoryboardFrame]

        var sceneID: String? { scene?.scene.sceneID ?? folder?.sceneID }
        var title: String { scene?.scene.heading ?? folder?.name ?? id }
    }

    let store: ProjectStore
    let script: ScriptWorkspace

    /// The frame the inspector shows.
    var selection: FrameRef?
    /// Every selected frame (⌘-click, ⌘A), including `selection`.
    var selected: Set<FrameRef> = []
    /// A row to scroll to.
    var focusedRow: String?
    /// Set to open the sketch pad.
    var sketchTarget: SketchTarget?
    /// Bumped when frames change, for views that cache.
    var version = 0
    private(set) var framesByFolder: [String: FramesFile] = [:]

    @ObservationIgnored weak var undoManager: UndoManager?
    let thumbnails = ThumbnailCache()

    struct SketchTarget: Identifiable, Equatable {
        let sceneID: String
        /// The frame being re-edited, if any.
        let file: String?
        var id: String { sceneID + "|" + (file ?? "new") }
    }

    init(store: ProjectStore, script: ScriptWorkspace) {
        self.store = store
        self.script = script
        refresh()
    }

    // MARK: - Reading

    var paths: [String] { (store.files[.storyboard] ?? []).map(\.relativePath) }

    /// Scenes with IDs, in script order.
    var scenes: [ScriptBook.Scene] { script.book.scenes.filter { $0.scene.sceneID != nil } }

    var plan: StoryboardFolders.Plan {
        StoryboardFolders.plan(scenes: scenes.map { ($0.scene.sceneID!, $0.scene.heading) },
                               folders: StoryboardFolders.folders(in: paths))
    }

    /// Re-reads every folder's frames. Call when files change.
    func refresh() {
        var result: [String: FramesFile] = [:]
        let all = paths
        for folder in StoryboardFolders.folders(in: all) {
            result[folder.path] = readFrames(folder, paths: all)
        }
        if result != framesByFolder {
            framesByFolder = result
            version += 1
        }
        if let selection, frame(selection) == nil { self.selection = nil }
        selected = selected.filter { frame($0) != nil }
    }

    /// `frames.json` (an open buffer wins), plus media dropped into the folder by hand, at the end.
    private func readFrames(_ folder: SceneFolder, paths: [String]) -> FramesFile {
        let jsonPath = folder.framesPath
        var file = FramesFile(scene: folder.sceneID ?? "")
        if let text = store.documents[jsonPath]?.text ?? (paths.contains(jsonPath) ? try? store.readText(at: jsonPath) : nil),
           let parsed = try? FramesFile(text: text) {
            file = parsed
        }
        let listed = Set(file.frames.map { $0.file.lowercased() })
        let loose = paths.filter { ($0 as NSString).deletingLastPathComponent == folder.path }
            .map { ($0 as NSString).lastPathComponent }
            .filter { StoryboardMedia.isMedia($0) && !listed.contains($0.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        file.frames += loose.map(StoryboardFrame.init(file:))
        return file
    }

    var rows: [Row] {
        let plan = plan
        var rows = scenes.map { scene -> Row in
            let folder = plan.boarded[scene.scene.sceneID!]
            return Row(id: scene.scene.sceneID!, kind: .scene, scene: scene, folder: folder,
                       frames: folder.flatMap { framesByFolder[$0.path]?.frames } ?? [])
        }
        rows += plan.missing.map { Row(id: $0.path, kind: .missing, scene: nil, folder: $0, frames: framesByFolder[$0.path]?.frames ?? []) }
        return rows
    }

    var orphanRows: [Row] {
        plan.orphans.map { Row(id: $0.path, kind: .orphan, scene: nil, folder: $0, frames: framesByFolder[$0.path]?.frames ?? []) }
    }

    func row(_ id: String) -> Row? {
        rows.first { $0.id == id } ?? orphanRows.first { $0.id == id }
    }

    func frame(_ ref: FrameRef) -> StoryboardFrame? {
        framesByFolder[ref.folder]?.frames.first { $0.file == ref.file }
    }

    /// The scene a folder belongs to.
    func scene(forFolder folder: String) -> ScriptBook.Scene? {
        guard let id = SceneFolder(path: folder).sceneID, plan.boarded[id]?.path == folder else { return nil }
        return scenes.first { $0.scene.sceneID == id }
    }

    /// The parsed file a scene lives in.
    func parsed(for scene: ScriptBook.Scene) -> ParsedScript? {
        script.book.files.first { $0.path == scene.file }?.parsed
    }

    /// The first action line, for an empty scene's placeholder.
    func firstAction(of scene: ScriptBook.Scene) -> String? {
        guard let parsed = parsed(for: scene) else { return nil }
        return scene.scene.lines.lazy.map { parsed.lines[$0] }.first { $0.kind == .action && !$0.isEmpty }?.text
    }

    /// Seconds on screen for each frame of a row.
    func durations(_ row: Row) -> [Double] {
        FrameTiming.durations(row.frames, sceneDuration: row.scene?.duration ?? 0) { [thumbnails, row] file in
            row.folder.flatMap { thumbnails.clipLength(for: $0.path + "/" + file) }
        }
    }

    /// The URL of a frame's file.
    func url(_ ref: FrameRef) -> URL? { try? store.url(for: ref.path) }

    // MARK: - Script ↔ frames

    /// Frames whose script lines include the script caret's line.
    var framesAtCaret: Set<FrameRef> {
        guard let caret = script.caret, let file = script.book.files.first(where: { $0.path == caret.file }) else { return [] }
        let parsed = file.parsed
        let line = parsed.lineIndex(containing: caret.location)
        guard let index = parsed.sceneIndex(containingLine: line), let id = parsed.scenes[index].sceneID else { return [] }
        return frames(covering: line, sceneID: id, parsed: parsed)
    }

    func frames(covering line: Int, sceneID: String, parsed: ParsedScript) -> Set<FrameRef> {
        guard let folder = plan.boarded[sceneID], let scene = parsed.scenes.first(where: { $0.sceneID == sceneID }) else { return [] }
        var result: Set<FrameRef> = []
        for frame in framesByFolder[folder.path]?.frames ?? [] {
            if let range = frame.scriptRange.flatMap(ScriptRange.init), range.covers(line: line, in: scene, of: parsed) {
                result.insert(FrameRef(folder: folder.path, file: frame.file))
            }
        }
        return result
    }

    /// Adds or removes a frame from the selection (⌘-click).
    func toggleSelection(_ ref: FrameRef) {
        if selected.contains(ref) {
            selected.remove(ref)
            if selection == ref { select(selected.first, keepingOthers: true) }
        } else {
            selected.insert(ref)
            select(ref, keepingOthers: true)
        }
    }

    /// ⌘A: every frame in the selected frame's row, or the focused row.
    func selectAll() {
        let rowID = selection.flatMap { ref in (rows + orphanRows).first { $0.folder?.path == ref.folder }?.id } ?? focusedRow
        guard let rowID, let row = row(rowID), let folder = row.folder else { return }
        let refs = row.frames.map { FrameRef(folder: folder.path, file: $0.file) }
        guard let first = refs.first else { return }
        selected = Set(refs)
        select(selection.flatMap { refs.contains($0) ? $0 : nil } ?? first, keepingOthers: true)
    }

    /// Selects a frame and tints its lines in the script.
    func select(_ ref: FrameRef?, keepingOthers: Bool = false) {
        if !keepingOthers { selected = ref.map { [$0] } ?? [] }
        selection = ref
        if let ref, let frame = frame(ref), let range = frame.scriptRange, let scene = scene(forFolder: ref.folder) {
            script.frameHighlight = FrameHighlight(sceneID: scene.scene.sceneID!, range: range)
        } else {
            script.frameHighlight = nil
        }
    }

    // MARK: - Writing frames.json

    /// Writes a folder's frames (through an open document if there is one) and registers undo.
    func write(_ file: FramesFile, folder: String, action: String? = nil) {
        let old = framesByFolder[folder]
        guard old != file else { return }
        save(file, folder: folder)
        if let action, let old, let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.write(old, folder: folder, action: action) }
            }
            undoManager.setActionName(action)
        }
    }

    func save(_ file: FramesFile, folder: String) {
        let path = folder + "/" + FramesFile.name
        do {
            if let document = try store.documents[path] ?? (paths.contains(path) ? store.document(at: path) : nil) {
                if (try? FramesFile(text: document.text)) != file { document.text = file.text }
                store.save(document)
            } else {
                _ = try store.createTextFile(at: path, contents: file.text)
            }
        } catch {
            SlateAppModel.showError("Couldn't save the storyboard", error)
        }
        framesByFolder[folder] = file
        version += 1
    }

    func update(_ ref: FrameRef, _ action: String, _ change: (inout StoryboardFrame) -> Void) {
        guard var file = framesByFolder[ref.folder], let index = file.index(of: ref.file) else { return }
        change(&file.frames[index])
        write(file, folder: ref.folder, action: action)
        if selection == ref { select(ref) }
    }

    // MARK: - Adding

    /// The folder for a scene, made up (not created) if it has none yet.
    func folder(forScene sceneID: String) -> String? {
        if let folder = plan.boarded[sceneID] { return folder.path }
        guard let scene = scenes.first(where: { $0.scene.sceneID == sceneID }) else { return nil }
        return StoryboardFolders.scenes + "/" + StoryboardFolders.folderName(sceneID: sceneID, heading: scene.scene.heading)
    }

    func names(in folder: String) -> Set<String> {
        Set(paths.filter { ($0 as NSString).deletingLastPathComponent == folder }.map { ($0 as NSString).lastPathComponent })
    }

    /// Copies files into a row's folder as new frames, at `index` (the end by default).
    @discardableResult
    func add(files urls: [URL], toRow rowID: String, at index: Int? = nil) -> [FrameRef] {
        guard let folder = row(rowID)?.folder?.path ?? folder(forScene: rowID) else { return [] }
        var taken = names(in: folder)
        var added: [String] = []
        for url in urls where StoryboardMedia.isMedia(url.lastPathComponent) {
            let name = StoryboardMedia.nextName(ext: url.pathExtension, existing: taken)
            do {
                let destination = try store.url(for: folder + "/" + name)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: destination)
                taken.insert(name)
                added.append(name)
            } catch {
                SlateAppModel.showError("Couldn't copy “\(url.lastPathComponent)”", error)
            }
        }
        return insert(added, folder: folder, at: index, action: urls.count == 1 ? "Add Frame" : "Add Frames")
    }

    /// Writes data (a pasted or sketched image) as a new frame.
    @discardableResult
    func add(data: Data, ext: String, toRow rowID: String, at index: Int? = nil, action: String = "Paste Frame") -> FrameRef? {
        guard let folder = row(rowID)?.folder?.path ?? folder(forScene: rowID) else { return nil }
        let name = StoryboardMedia.nextName(ext: ext, existing: names(in: folder))
        do {
            try CoordinatedFileIO.write(data, to: try store.url(for: folder + "/" + name))
        } catch {
            SlateAppModel.showError("Couldn't save the frame", error)
            return nil
        }
        return insert([name], folder: folder, at: index, action: action).first
    }

    private func insert(_ names: [String], folder: String, at index: Int?, action: String) -> [FrameRef] {
        guard !names.isEmpty else { return [] }
        store.rescan()
        // The folder now exists; frames.json starts from what's there.
        var file = framesByFolder[folder] ?? FramesFile(scene: SceneFolder(path: folder).sceneID ?? "")
        file.frames.removeAll { names.contains($0.file) }
        let position = min(index ?? file.frames.count, file.frames.count)
        file.frames.insert(contentsOf: names.map(StoryboardFrame.init(file:)), at: position)
        save(file, folder: folder)
        store.rescan()
        refresh()
        let refs = names.map { FrameRef(folder: folder, file: $0) }
        select(refs.first)
        // Undo sends the new frames to the Trash (and redo brings them back).
        if let undoManager = registrableUndo {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.delete(refs, action: action) }
            }
            undoManager.setActionName(action)
        }
        return refs
    }

    /// Images or image files on the pasteboard.
    func paste(from pasteboard: NSPasteboard = .general, toRow rowID: String) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { StoryboardMedia.isMedia($0.lastPathComponent) }) {
            return !add(files: urls, toRow: rowID).isEmpty
        }
        guard let image = NSImage(pasteboard: pasteboard), let png = image.pngData else { return false }
        return add(data: png, ext: "png", toRow: rowID) != nil
    }

    // MARK: - Moving and deleting

    /// Moves a frame to `index` in a row: a reorder inside its own folder,
    /// or a file move (renamed if the name is taken) into another scene's folder.
    func move(_ ref: FrameRef, toRow rowID: String, at index: Int) {
        guard let target = row(rowID)?.folder?.path ?? folder(forScene: rowID),
              var source = framesByFolder[ref.folder], let from = source.index(of: ref.file) else { return }
        if target == ref.folder {
            var to = min(max(index, 0), source.frames.count)
            let frame = source.frames.remove(at: from)
            if to > from { to -= 1 }
            source.frames.insert(frame, at: min(to, source.frames.count))
            write(source, folder: ref.folder, action: "Reorder Frames")
            return
        }
        var frame = source.frames.remove(at: from)
        let name = StoryboardMedia.freeName(ref.file, existing: names(in: target))
        do {
            try store.moveFile(from: ref.path, to: target + "/" + name)
            let strokes = StoryboardMedia.strokesFile(for: ref.file)
            if paths.contains(ref.folder + "/" + strokes) {
                try store.moveFile(from: ref.folder + "/" + strokes, to: target + "/" + StoryboardMedia.strokesFile(for: name))
            }
        } catch {
            SlateAppModel.showError("Couldn't move the frame", error)
            return
        }
        frame.file = name
        save(source, folder: ref.folder)
        store.rescan()
        refresh()
        var destination = framesByFolder[target] ?? FramesFile(scene: SceneFolder(path: target).sceneID ?? "")
        destination.frames.removeAll { $0.file == name }
        destination.frames.insert(frame, at: min(index, destination.frames.count))
        save(destination, folder: target)
        refresh()
        let moved = FrameRef(folder: target, file: name)
        select(moved)
        // Undo moves it back to where it was.
        if let undoManager, let back = row(forFolder: ref.folder) {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.move(moved, toRow: back, at: from) }
            }
            undoManager.setActionName("Move Frame")
        }
    }

    private func row(forFolder folder: String) -> String? {
        (rows + orphanRows).first { $0.folder?.path == folder }?.id
    }

    func delete(_ ref: FrameRef) { delete([ref]) }

    /// Sends frames' files (and sketch strokes) to the Trash and drops them from
    /// their lists. Undo puts the files back from the Trash.
    func delete(_ refs: [FrameRef], action: String? = nil) {
        let action = action ?? (refs.count == 1 ? "Delete Frame" : "Delete Frames")
        var trashed: [(path: String, trash: URL)] = []
        var before: [String: FramesFile] = [:]
        for ref in refs {
            guard var file = framesByFolder[ref.folder] else { continue }
            if before[ref.folder] == nil { before[ref.folder] = file }
            for path in [ref.path, ref.folder + "/" + StoryboardMedia.strokesFile(for: ref.file)] where paths.contains(path) {
                do {
                    if let url = try store.trashFile(path) { trashed.append((path, url)) }
                } catch {
                    SlateAppModel.showError("Couldn't move the frame to the Trash", error)
                }
            }
            file.frames.removeAll { $0.file == ref.file }
            save(file, folder: ref.folder)
        }
        if let selection, refs.contains(selection) { select(nil) }
        selected.subtract(refs)
        refresh()
        guard let undoManager = registrableUndo, !before.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(trashed, lists: before, refs: refs, action: action) }
        }
        undoManager.setActionName(action)
    }

    /// Undoes a delete: files back from the Trash, lists as they were.
    private func restore(_ trashed: [(path: String, trash: URL)], lists: [String: FramesFile], refs: [FrameRef], action: String) {
        for item in trashed {
            do {
                let destination = try store.url(for: item.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.trash, to: destination)
            } catch {
                SlateAppModel.showError("Couldn't bring “\((item.path as NSString).lastPathComponent)” back from the Trash", error)
            }
        }
        store.rescan()
        for (folder, file) in lists { save(file, folder: folder) }
        refresh()
        selected = Set(refs)
        select(refs.first, keepingOthers: true)
        registrableUndo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.delete(refs, action: action) }
        }
        registrableUndo?.setActionName(action)
    }

    /// The undo manager, when it can take a registration now (an open group, or
    /// automatic grouping as in the app).
    private var registrableUndo: UndoManager? {
        guard let undoManager, undoManager.groupsByEvent || undoManager.groupingLevel > 0 || undoManager.isUndoing || undoManager.isRedoing else { return nil }
        return undoManager
    }

    // MARK: - Folders: renames, missing scenes, orphans

    /// Renames folders whose heading changed and, if asked, moves boards whose
    /// scene is gone into `orphans/`. Never runs while typing: on open, on close, or on request.
    func tidyFolders(moveMissing: Bool) {
        let plan = plan
        for rename in plan.renames { moveFolder(rename.from, to: rename.to) }
        // A script that failed to load (or is empty) would orphan everything.
        guard moveMissing, !scenes.isEmpty else { return }
        for folder in plan.missing { moveToOrphans(folder) }
    }

    func moveToOrphans(_ folder: SceneFolder) {
        let existing = Set(StoryboardFolders.folders(in: paths).filter(\.isOrphan).map(\.path))
        moveFolder(folder.path, to: StoryboardFolders.orphanPath(for: folder, existing: existing))
    }

    /// Gives a missing or orphaned board to a scene that has none.
    func reattach(_ board: SceneFolder, toScene sceneID: String) {
        guard plan.boarded[sceneID] == nil, let destination = folder(forScene: sceneID) else { return }
        moveFolder(board.path, to: destination)
        if var file = framesByFolder[destination] {
            file.scene = sceneID
            save(file, folder: destination)
        }
        focusedRow = sceneID
    }

    private func moveFolder(_ from: String, to: String) {
        guard from != to else { return }
        // Documents inside the folder are saved and closed first.
        for (path, document) in store.documents where path.hasPrefix(from + "/") { store.closeDocument(document) }
        do {
            try store.moveFile(from: from, to: to)
        } catch {
            SlateAppModel.showError("Couldn't move the board folder “\((from as NSString).lastPathComponent)”", error)
            return
        }
        if let selection, selection.folder == from { self.selection = FrameRef(folder: to, file: selection.file) }
        refresh()
    }

    // MARK: - Sketches

    /// Saves a sketch as a PNG with its strokes beside it, as a new frame or over the one being edited.
    func saveSketch(_ strokes: SketchStrokes, png: Data, target: SketchTarget) {
        if let file = target.file, let folder = plan.boarded[target.sceneID]?.path {
            do {
                try CoordinatedFileIO.write(png, to: try store.url(for: folder + "/" + file))
                try CoordinatedFileIO.write(strokes.data, to: try store.url(for: folder + "/" + StoryboardMedia.strokesFile(for: file)))
            } catch {
                SlateAppModel.showError("Couldn't save the sketch", error)
            }
            thumbnails.forget(folder + "/" + file)
            store.rescan()
            refresh()
            version += 1
            return
        }
        guard let ref = add(data: png, ext: "png", toRow: target.sceneID, action: "New Sketch") else { return }
        do {
            try CoordinatedFileIO.write(strokes.data, to: try store.url(for: ref.folder + "/" + StoryboardMedia.strokesFile(for: ref.file)))
        } catch {
            SlateAppModel.showError("Couldn't save the sketch's strokes", error)
        }
        store.rescan()
    }

    /// A sketch's strokes, if it has them.
    func strokes(for ref: FrameRef) -> SketchStrokes? {
        let path = ref.folder + "/" + StoryboardMedia.strokesFile(for: ref.file)
        guard paths.contains(path), let url = try? store.url(for: path), let data = try? Data(contentsOf: url) else { return nil }
        return try? SketchStrokes(data: data)
    }

    /// The sketch guide new sketches start with (`storyboard.json` › settings › guide).
    var defaultGuide: SketchGuide { settings.guide }
}

extension NSImage {
    /// PNG bytes of the image.
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
