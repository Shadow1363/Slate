import AVFoundation
import Foundation
import SlateCore
import SlateExport

/// The storyboard's side of the animatic: settings, scratch audio, the temp
/// score, and turning the boards into an `AnimaticTimeline`.
extension StoryboardModel {
    // MARK: - storyboard.json

    /// `storyboard.json` (an open buffer wins); defaults if it's missing or unreadable.
    var settings: StoryboardSettings {
        let path = StoryboardFolders.settings
        guard let text = store.documents[path]?.text ?? (paths.contains(path) ? try? store.readText(at: path) : nil) else {
            return StoryboardSettings()
        }
        return (try? StoryboardSettings(text: text)) ?? StoryboardSettings()
    }

    /// Changes `storyboard.json` through the store, with undo when there's an action name.
    func updateSettings(_ action: String?, _ change: (inout StoryboardSettings) -> Void) {
        let old = settings
        var new = old
        change(&new)
        guard new != old else { return }
        writeSettings(new)
        if let action, let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.updateSettings(action) { $0 = old } }
            }
            undoManager.setActionName(action)
        }
    }

    private func writeSettings(_ settings: StoryboardSettings) {
        let path = StoryboardFolders.settings
        do {
            if let document = try store.documents[path] ?? (paths.contains(path) ? store.document(at: path) : nil) {
                document.text = settings.text
                store.save(document)
            } else {
                _ = try store.createTextFile(at: path, contents: settings.text)
            }
        } catch {
            SlateAppModel.showError("Couldn't save the storyboard settings", error)
        }
        version += 1
    }

    // MARK: - Scratch audio

    func scratchAudio(_ row: Row) -> String? {
        row.folder.flatMap { framesByFolder[$0.path]?.scratchAudio }
    }

    /// Copies a sound file into the scene's folder as its scratch track (replacing any old one).
    func setScratchAudio(_ url: URL, row rowID: String) {
        guard StoryboardMedia.isAudio(url.lastPathComponent),
              let folder = row(rowID)?.folder?.path ?? folder(forScene: rowID) else { return }
        let old = framesByFolder[folder]?.scratchAudio
        do {
            // The old track goes to the Trash first, so the new one can take its name.
            if let old, paths.contains(folder + "/" + old) {
                try store.trashFile(folder + "/" + old)
                store.rescan()
            }
            let name = StoryboardMedia.freeName("scratch." + url.pathExtension.lowercased(), existing: names(in: folder))
            let destination = try store.url(for: folder + "/" + name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
            store.rescan()
            refresh()
            var file = framesByFolder[folder] ?? FramesFile(scene: SceneFolder(path: folder).sceneID ?? "")
            file.scratchAudio = name
            save(file, folder: folder)
            refresh()
        } catch {
            SlateAppModel.showError("Couldn't add “\(url.lastPathComponent)”", error)
        }
    }

    /// Sends the scratch track to the Trash.
    func removeScratchAudio(row rowID: String) {
        guard let folder = row(rowID)?.folder?.path, var file = framesByFolder[folder], let name = file.scratchAudio else { return }
        do {
            if paths.contains(folder + "/" + name) { try store.trashFile(folder + "/" + name) }
        } catch {
            SlateAppModel.showError("Couldn't move the scratch audio to the Trash", error)
            return
        }
        file.scratchAudio = nil
        file.scratchVolume = nil
        save(file, folder: folder)
        refresh()
    }

    func setScratchVolume(_ volume: Double, row rowID: String) {
        guard let folder = row(rowID)?.folder?.path, var file = framesByFolder[folder] else { return }
        file.scratchVolume = volume >= 0.995 ? nil : volume
        write(file, folder: folder, action: "Change Volume")
    }

    // MARK: - Temp score

    /// Copies a sound file into `storyboard/` as the project's temp score.
    func setScore(_ url: URL) {
        guard StoryboardMedia.isAudio(url.lastPathComponent) else { return }
        let old = settings.scorePath
        let name: String
        do {
            if let old, paths.contains(old) {
                try store.trashFile(old)
                store.rescan()
            }
            name = StoryboardMedia.freeName("score." + url.pathExtension.lowercased(), existing: names(in: "storyboard"))
            let destination = try store.url(for: "storyboard/" + name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            SlateAppModel.showError("Couldn't add “\(url.lastPathComponent)”", error)
            return
        }
        store.rescan()
        // Copying a file isn't undoable, so neither is this.
        updateSettings(nil) { $0.score = name }
    }

    func removeScore() {
        guard let path = settings.scorePath else { return }
        do {
            if paths.contains(path) { try store.trashFile(path) }
        } catch {
            SlateAppModel.showError("Couldn't move the temp score to the Trash", error)
            return
        }
        updateSettings(nil) {
            $0.score = nil
            $0.scoreVolume = nil
        }
    }

    // MARK: - Timeline

    /// Every scene with an ID, with its board.
    var animaticScenes: [AnimaticScene] {
        var boards: [String: (folder: String, frames: FramesFile)] = [:]
        for (id, folder) in plan.boarded {
            boards[id] = (folder.path, framesByFolder[folder.path] ?? FramesFile(scene: id))
        }
        return AnimaticScene.all(in: script.book, boards: boards)
    }

    /// The animatic for a range.
    /// - Parameter clipLengths: Clip lengths by path, for clips that set no `out` or duration.
    func timeline(_ range: AnimaticRange = .film, clipLengths: [String: Double] = [:]) -> AnimaticTimeline {
        AnimaticTimeline.build(scenes: animaticScenes, settings: settings, range: range) { [thumbnails] path in
            clipLengths[path] ?? thumbnails.clipLength(for: path)
        }
    }

    /// Reads the length of every clip that needs it (no `out` and no duration).
    func loadClipLengths() async -> [String: Double] {
        var needed: [String: URL] = [:]
        for (folder, file) in framesByFolder {
            for frame in file.frames where frame.isClip && frame.outPoint == nil && frame.duration == nil {
                let path = folder + "/" + frame.file
                if let url = try? store.url(for: path) { needed[path] = url }
            }
        }
        var result: [String: Double] = [:]
        for (path, url) in needed {
            if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite {
                result[path] = seconds
            }
        }
        return result
    }

    /// The scene and frame a timeline segment shows, to select it on the board.
    func ref(for segment: AnimaticSegment) -> FrameRef? {
        guard let folder = segment.folder, let file = segment.file else { return nil }
        return FrameRef(folder: folder, file: file)
    }
}
