import AppKit
import Observation
import SlateCore

/// One open `*.map.json`: the file, the base image, the view and the tools.
@MainActor
@Observable
final class MapModel: ZoomPanTarget {
    enum Tool: String, CaseIterable, Identifiable {
        case select, pin, region, path
        var id: String { rawValue }

        var title: String {
            switch self {
            case .select: "Select"
            case .pin: "Pin"
            case .region: "Region"
            case .path: "Path"
            }
        }

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .pin: "mappin"
            case .region: "skew"
            case .path: "point.topleft.down.to.point.bottomright.curvepath"
            }
        }
    }

    let file: FileBackedModel<MapFile>
    let path: String

    var tool: Tool = .select {
        didSet { if tool != oldValue { draft = [] } }
    }
    var selection: String?
    /// Corners of the region or path being drawn.
    var draft: [MapPoint] = []
    /// Layers switched off in this window (not saved: the file stays the same for everyone).
    var hiddenLayers: Set<String> = []
    /// The layer new items go on; nil for "always shown".
    var currentLayer: String?
    /// An item to point out (from "Show on Map").
    var highlighted: String?

    private(set) var image: NSImage?
    @ObservationIgnored private var loadedImage: String?

    /// View point = map point (0–1) × size × scale + offset.
    var scale: Double = 1
    var offset = CGPoint(x: 40, y: 40)
    var viewSize = CGSize(width: 800, height: 600)
    @ObservationIgnored var hasFitted = false

    static let minScale = 0.05
    static let maxScale = 8.0
    static let gridWidth = 1200.0

    init(document: TextDocument, store: ProjectStore) {
        path = document.relativePath
        file = FileBackedModel(document: document, empty: MapFile())
        file.onReload = { [weak self] fresh in
            guard let self else { return }
            if let id = selection, fresh.item(id) == nil { selection = nil }
        }
        reloadImage(store: store)
    }

    var map: MapFile { file.value }

    func edit(_ action: String, _ change: (MapFile) -> MapFile) {
        file.edit(action, change)
    }

    // MARK: Image

    /// The image's path from the project root, if the map has one.
    var imagePath: String? {
        map.image.map { MapFile.imagePath($0, mapPath: path) }
    }

    /// Loads the base image again if the file now names a different one.
    func reloadImage(store: ProjectStore, force: Bool = false) {
        let wanted = imagePath
        guard force || wanted != loadedImage else { return }
        loadedImage = wanted
        image = wanted.flatMap { try? store.url(for: $0) }.flatMap(NSImage.init(contentsOf:))
    }

    /// The map's size in points at 100%.
    var size: CGSize {
        if let image, image.size.width > 0, image.size.height > 0 { return image.size }
        return CGSize(width: Self.gridWidth, height: Self.gridWidth / map.aspect)
    }

    /// Width ÷ height, for even hit distances.
    var aspect: Double { size.width / size.height }

    // MARK: Coordinates

    func view(_ point: MapPoint) -> CGPoint {
        CGPoint(x: offset.x + point.x * size.width * scale, y: offset.y + point.y * size.height * scale)
    }

    func mapPoint(_ point: CGPoint) -> MapPoint {
        MapPoint(x: (point.x - offset.x) / (size.width * scale), y: (point.y - offset.y) / (size.height * scale))
    }

    var mapRect: CGRect {
        CGRect(x: offset.x, y: offset.y, width: size.width * scale, height: size.height * scale)
    }

    // MARK: Viewport

    func pan(by dx: Double, _ dy: Double) {
        offset.x += dx
        offset.y += dy
    }

    func zoom(by factor: Double, around anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        let before = CGPoint(x: (anchor.x - offset.x) / scale, y: (anchor.y - offset.y) / scale)
        scale = newScale
        offset = CGPoint(x: anchor.x - before.x * newScale, y: anchor.y - before.y * newScale)
    }

    func fit() {
        let margin = 30.0
        scale = min(max(min((viewSize.width - margin * 2) / size.width, (viewSize.height - margin * 2) / size.height), Self.minScale), 2)
        offset = CGPoint(x: (viewSize.width - size.width * scale) / 2, y: (viewSize.height - size.height * scale) / 2)
    }

    /// Centres the view on an item.
    func centre(on id: String) {
        guard let item = map.item(id) else { return }
        let centre = MapGeometry.centre(item.points)
        offset = CGPoint(x: viewSize.width / 2 - centre.x * size.width * scale, y: viewSize.height / 2 - centre.y * size.height * scale)
    }

    // MARK: Items

    func isVisible(_ item: MapItem) -> Bool {
        item.layer.map { !hiddenLayers.contains($0) } ?? true
    }

    var visibleItems: [MapItem] { map.items.filter(isVisible) }

    /// The topmost visible item under a view point: pins, then paths, then regions.
    func item(at point: CGPoint) -> MapItem? {
        let p = mapPoint(point)
        let tolerance = 10 / (size.height * scale)
        for item in visibleItems {
            switch item.kind {
            case .pin:
                let pin = view(item.points[0])
                // The pin's head sits above its point.
                if hypot(point.x - pin.x, point.y - (pin.y - 14)) < 16 { return item }
            case .path:
                if MapGeometry.distance(from: p, to: item.points, aspect: aspect) < tolerance { return item }
            case .region:
                if MapGeometry.contains(item.points, p) { return item }
            }
        }
        return nil
    }

    func addPin(at point: CGPoint, title: String = "New pin", note: String? = nil) {
        let id = MapEditing.newID(.pin, in: map)
        var item = MapItem(kind: .pin, id: id, title: title, points: [mapPoint(point).clamped], layer: currentLayer)
        item.note = note
        edit("Add Pin") { MapEditing.adding(item, to: $0) }
        selection = id
    }

    /// Ends the region or path being drawn.
    func finishDraft() {
        let kind: MapItem.Kind = tool == .region ? .region : .path
        let needed = kind == .region ? 3 : 2
        defer { draft = [] }
        guard tool == .region || tool == .path, draft.count >= needed else { return }
        let id = MapEditing.newID(kind, in: map)
        let item = MapItem(kind: kind, id: id, title: kind == .region ? "New region" : "New path", points: draft, layer: currentLayer)
        edit(kind == .region ? "Add Region" : "Add Path") { MapEditing.adding(item, to: $0) }
        selection = id
        tool = .select
    }

    func deleteSelection() {
        guard let id = selection else { return }
        edit("Delete") { MapEditing.removing([id], from: $0) }
        selection = nil
    }
}
