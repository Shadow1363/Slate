import AppKit
import SlateCore

/// Creating canvases' siblings (timelines, maps) and finding a scene's place on a map.
extension ProjectSession {
    /// A free path like `universe/timelines/untitled-2.timeline.json`.
    private func freePath(folder: String, stem: String, suffix: String) -> String {
        let existing = Set(allPaths.map { $0.lowercased() })
        var path = "\(folder)/\(stem)\(suffix)"
        var counter = 2
        while existing.contains(path) {
            path = "\(folder)/\(stem)-\(counter)\(suffix)"
            counter += 1
        }
        return path
    }

    /// Makes `universe/timelines/untitled.timeline.json` and opens it.
    func createTimeline() {
        let path = freePath(folder: "universe/timelines", stem: "untitled", suffix: TimelineFile.suffix)
        do {
            try store.createTextFile(at: path, contents: TimelineFile.empty)
            open(path)
        } catch {
            SlateAppModel.showError("Couldn't create the timeline", error)
        }
    }

    /// Makes `universe/maps/untitled.map.json` (a blank grid until an image is added) and opens it.
    func createMap() {
        let path = freePath(folder: "universe/maps", stem: "untitled", suffix: MapFile.suffix)
        do {
            try store.createTextFile(at: path, contents: MapFile.empty)
            open(path)
        } catch {
            SlateAppModel.showError("Couldn't create the map", error)
        }
    }

    var timelineFiles: [String] {
        universePaths.filter { $0.lowercased().hasSuffix(TimelineFile.suffix) }
    }

    var mapFiles: [String] {
        universePaths.filter { $0.lowercased().hasSuffix(MapFile.suffix) }
    }

    private var universePaths: [String] {
        (store.files[.universe] ?? []).map(\.relativePath)
    }

    /// Images a map uses as its base layer (kept out of "Other Files").
    var mapImages: Set<String> {
        var images: Set<String> = []
        for path in mapFiles {
            guard let text = try? store.readText(at: path), let map = try? MapFile(text: text), let image = map.image else { continue }
            images.insert(MapFile.imagePath(image, mapPath: path))
        }
        return images
    }

    /// The first map item for a scene: one linked to the scene itself, else
    /// one linked to the location note its heading names (`INT. THE STATION`).
    func mapTarget(for scene: ScriptBook.Scene) -> MapRevealRequest? {
        let sceneID = scene.scene.sceneID
        let location = SceneHeading.parse(scene.scene.heading).parts.location
        let graph = links.graph
        let place = location.isEmpty ? nil : graph.resolve(location)?.path
        var byPlace: MapRevealRequest?
        for path in mapFiles {
            guard let text = try? store.readText(at: path), let map = try? MapFile(text: text) else { continue }
            for item in map.items {
                if let sceneID, item.scenes.contains(sceneID) { return MapRevealRequest(path: path, item: item.id) }
                if byPlace == nil, let place, let note = item.note, graph.resolve(note)?.path == place {
                    byPlace = MapRevealRequest(path: path, item: item.id)
                }
            }
        }
        return byPlace
    }

    func showOnMap(_ scene: ScriptBook.Scene) {
        guard let target = mapTarget(for: scene) else { return }
        mapReveal = target
        open(target.path)
    }
}
