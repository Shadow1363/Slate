import Foundation

/// The first storyboard image of a project, for its Home card.
public enum StoryboardCover {
    /// The first image frame of the earliest boarded scene (clips are skipped).
    public static func firstImage(in root: URL) -> URL? {
        let fm = FileManager.default
        let scenesURL = root.appending(path: StoryboardFolders.scenes, directoryHint: .isDirectory)
        guard let folders = try? fm.contentsOfDirectory(atPath: scenesURL.path), !folders.isEmpty else { return nil }
        let byID = Dictionary(folders.compactMap { name in StoryboardFolders.sceneID(fromFolderName: name).map { ($0, name) } },
                              uniquingKeysWith: { first, _ in first })
        // Scene order from the script; folders whose scene isn't found come after, by name.
        let scriptURL = root.appending(path: ProjectLayout.script, directoryHint: .isDirectory)
        let scriptNames = ((try? fm.contentsOfDirectory(atPath: scriptURL.path)) ?? [])
            .filter { $0 != "title-page.md" && ["md", "fountain", "txt"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var order: [String] = []
        for name in scriptNames {
            guard let text = try? String(contentsOf: scriptURL.appending(path: name), encoding: .utf8) else { continue }
            order += ScriptParser.parse(text).scenes.compactMap(\.sceneID)
        }
        let ordered = order.compactMap { byID[$0] } + folders.sorted().filter { !Set(order.compactMap { byID[$0] }).contains($0) }
        for name in ordered {
            let folder = scenesURL.appending(path: name, directoryHint: .isDirectory)
            var files: [String] = []
            if let text = try? String(contentsOf: folder.appending(path: FramesFile.name), encoding: .utf8),
               let frames = try? FramesFile(text: text) {
                files = frames.frames.map(\.file)
            }
            files += ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            if let image = files.first(where: { StoryboardMedia.isMedia($0) && !StoryboardMedia.isClip($0) && fm.fileExists(atPath: folder.appending(path: $0).path) }) {
                return folder.appending(path: image)
            }
        }
        return nil
    }
}
