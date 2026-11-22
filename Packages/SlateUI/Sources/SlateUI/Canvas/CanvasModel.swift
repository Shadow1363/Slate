import AppKit
import Observation
import SlateCore

/// One open `.canvas` board. Edits go through the file's `TextDocument`
/// (written 0.3 s after the last change), so autosave, outside reloads and
/// conflict banners work as for any file. Each edit is one undo step.
@MainActor
@Observable
final class CanvasModel {
    let document: TextDocument
    private(set) var canvas: CanvasFile
    private(set) var parseError: String?

    var selection: Set<String> = []
    var selectedEdge: String?
    /// The text card being typed in.
    var editingText: String?

    /// View point = world point × scale + offset.
    var scale: Double = 1
    var offset = CGPoint(x: 80, y: 80)
    var viewSize = CGSize(width: 800, height: 600)

    @ObservationIgnored weak var undoManager: UndoManager?
    /// The text last written to (or read from) the document.
    @ObservationIgnored private var syncedText: String
    @ObservationIgnored private var writeWork: DispatchWorkItem?
    /// The canvas before a drag started, for one undo step per drag.
    @ObservationIgnored private var interactionStart: CanvasFile?

    static let minScale = 0.1
    static let maxScale = 4.0

    init(document: TextDocument) {
        self.document = document
        syncedText = document.text
        do {
            canvas = try CanvasFile(text: document.text)
        } catch {
            canvas = CanvasFile()
            parseError = error.localizedDescription
        }
    }

    // MARK: - File sync

    /// Call when the document's text may have changed underneath (a reload from disk).
    func documentChanged() {
        guard document.text != syncedText else { return }
        syncedText = document.text
        writeWork?.cancel()
        do {
            let fresh = try CanvasFile(text: document.text)
            parseError = nil
            if fresh != canvas {
                canvas = fresh
                let ids = Set(fresh.nodes.map(\.id))
                selection = selection.filter(ids.contains)
                if let edge = selectedEdge, !fresh.edges.contains(where: { $0.id == edge }) { selectedEdge = nil }
            }
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func scheduleWrite() {
        writeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        writeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes pending edits to the document now.
    func flush() {
        writeWork?.cancel()
        writeWork = nil
        guard parseError == nil else { return }
        // Unchanged canvases are never rewritten, so files from other apps keep their formatting.
        if let current = try? CanvasFile(text: document.text), current == canvas { return }
        let text = canvas.text
        syncedText = text
        if document.text != text { document.text = text }
    }

    // MARK: - Editing

    /// Replaces the canvas as one undoable step.
    func apply(_ new: CanvasFile, _ action: String) {
        guard new != canvas, parseError == nil else { return }
        let old = canvas
        canvas = new
        registerUndo(back: old, action)
        scheduleWrite()
    }

    private func registerUndo(back old: CanvasFile, _ action: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.apply(old, action) }
        }
        undoManager.setActionName(action)
    }

    /// Starts a drag: changes until `endInteraction` are one undo step.
    func beginInteraction() {
        if interactionStart == nil { interactionStart = canvas }
    }

    /// A live change during a drag (no undo step yet).
    func update(_ new: CanvasFile) {
        guard parseError == nil else { return }
        beginInteraction()
        canvas = new
    }

    func endInteraction(_ action: String) {
        guard let start = interactionStart else { return }
        interactionStart = nil
        guard start != canvas else { return }
        registerUndo(back: start, action)
        scheduleWrite()
    }

    func edit(_ action: String, _ change: (CanvasFile) -> CanvasFile) {
        apply(change(canvas), action)
    }

    // MARK: - Adding

    /// Where a new card goes: the centre of the view, offset a little each time.
    func newCardRect(width: Double = 260, height: Double = 140) -> CanvasRect {
        let centre = world(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        let nudge = Double(canvas.nodes.count % 5) * 20
        return CanvasRect(x: CanvasEditing.snap(centre.x - width / 2 + nudge), y: CanvasEditing.snap(centre.y - height / 2 + nudge),
                          width: width, height: height)
    }

    @discardableResult
    func add(_ node: CanvasNode, _ action: String = "Add Card") -> String {
        apply(CanvasEditing.adding(node, to: canvas), action)
        selection = [node.id]
        selectedEdge = nil
        return node.id
    }

    func addText(at rect: CanvasRect? = nil, text: String = "") {
        let node = CanvasEditing.textCard(text, at: rect ?? newCardRect(), in: canvas)
        add(node, "Add Text Card")
        editingText = node.id
    }

    func deleteSelection() {
        var ids = selection
        if let edge = selectedEdge { ids.insert(edge) }
        guard !ids.isEmpty else { return }
        edit("Delete") { CanvasEditing.removing(ids, from: $0) }
        selection = []
        selectedEdge = nil
    }

    func groupSelection() {
        if selection.isEmpty {
            add(CanvasEditing.group("Group", at: newCardRect(width: 400, height: 300), in: canvas), "Add Group")
            return
        }
        guard let (grouped, id) = CanvasEditing.grouping(selection, label: "Group", in: canvas) else { return }
        apply(grouped, "Group")
        selection = [id]
    }

    // MARK: - Viewport

    func world(_ point: CGPoint) -> (x: Double, y: Double) {
        ((point.x - offset.x) / scale, (point.y - offset.y) / scale)
    }

    func view(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * scale + offset.x, y: y * scale + offset.y)
    }

    func viewRect(_ rect: CanvasRect) -> CGRect {
        CGRect(x: rect.x * scale + offset.x, y: rect.y * scale + offset.y, width: rect.width * scale, height: rect.height * scale)
    }

    /// The part of the world that's on screen.
    var visibleWorld: CanvasRect {
        let origin = world(.zero)
        return CanvasRect(x: origin.x, y: origin.y, width: viewSize.width / scale, height: viewSize.height / scale)
    }

    func pan(by dx: Double, _ dy: Double) {
        offset.x += dx
        offset.y += dy
    }

    /// Zooms by `factor`, keeping the world point under `anchor` still.
    func zoom(by factor: Double, around anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        let before = world(anchor)
        scale = newScale
        offset = CGPoint(x: anchor.x - before.x * newScale, y: anchor.y - before.y * newScale)
    }

    func zoomToActualSize() {
        zoom(by: 1 / scale)
    }

    /// Fits every card (or the selection) in the view.
    func fit(selectionOnly: Bool = false) {
        let nodes = selectionOnly && !selection.isEmpty ? canvas.nodes.filter { selection.contains($0.id) } : canvas.nodes
        guard let first = nodes.first?.rect else {
            scale = 1
            offset = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            return
        }
        let box = nodes.dropFirst().reduce(first) { $0.union($1.rect) }
        let margin = 60.0
        let fit = min((viewSize.width - margin * 2) / max(box.width, 1), (viewSize.height - margin * 2) / max(box.height, 1))
        scale = min(max(fit, Self.minScale), 1.5)
        offset = CGPoint(x: viewSize.width / 2 - box.midX * scale, y: viewSize.height / 2 - box.midY * scale)
    }

    /// Centres the view on a world point (the minimap).
    func centre(on x: Double, _ y: Double) {
        offset = CGPoint(x: viewSize.width / 2 - x * scale, y: viewSize.height / 2 - y * scale)
    }

    /// The topmost node under a view point.
    func node(at point: CGPoint, includingGroups: Bool = true) -> CanvasNode? {
        let p = world(point)
        let hit = CanvasRect(x: p.x, y: p.y, width: 0.001, height: 0.001)
        return canvas.nodes.last { (includingGroups || $0.kind != .group) && $0.rect.intersects(hit) }
    }
}
