import AppKit
import SlateCore
import SwiftUI
import UniformTypeIdentifiers

/// A `.canvas` file in the Universe area.
struct CanvasPane: View {
    let session: ProjectSession
    let document: TextDocument
    @State private var model: CanvasModel
    @Environment(\.undoManager) private var undoManager

    init(session: ProjectSession, document: TextDocument) {
        self.session = session
        self.document = document
        _model = State(initialValue: CanvasModel(document: document))
    }

    var body: some View {
        VStack(spacing: 0) {
            DiskStateBanners(store: session.store, document: document, close: { session.universeSelection = nil })
            if let error = model.parseError {
                Banner(systemImage: "exclamationmark.triangle.fill", message: "This canvas can't be read: \(error) Fix the file and it reloads.") {}
                DocumentEditor(store: session.store, document: document, close: { session.universeSelection = nil })
            } else {
                CanvasBoard(session: session, model: model)
            }
        }
        .navigationTitle(((document.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension)
        .toolbar { CanvasToolbar(session: session, model: model) }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: document.text) { model.documentChanged() }
        .onDisappear { model.flush() }
    }
}

// MARK: - The board

struct CanvasBoard: View {
    let session: ProjectSession
    @Bindable var model: CanvasModel
    @AppStorage("canvasSnapToGrid") private var snapToGrid = true
    @AppStorage("canvasShowMinimap") private var showMinimap = true
    @Environment(\.slateTheme) private var theme
    @FocusState private var focused: Bool

    @State private var dragStart: CanvasFile?
    @State private var marquee: CGRect?
    @State private var panStart: CGPoint?
    @State private var connection: (from: String, side: CanvasEdge.Side, to: CGPoint)?
    @State private var hovered: String?
    @State private var events = CanvasEventMonitor()

    var body: some View {
        GeometryReader { geometry in
            let visible = model.visibleWorld
            let shown = model.canvas.nodes.filter { visible.intersects($0.rect) || model.selection.contains($0.id) }
            ZStack(alignment: .topLeading) {
                background
                ForEach(shown.filter { $0.kind == .group }) { node in
                    nodeView(node) { CanvasGroupView(node: node, scale: model.scale) }
                }
                CanvasEdgesLayer(model: model, connector: Color(theme.canvas.connector))
                    .allowsHitTesting(false)
                ForEach(shown.filter { $0.kind != .group }) { node in
                    nodeView(node) { CanvasCardView(session: session, model: model, node: node) }
                }
                if let connection, let from = model.canvas.node(connection.from) {
                    let a = CanvasEditing.anchor(from.rect, connection.side)
                    Path { path in
                        path.move(to: model.view(a.x, a.y))
                        path.addLine(to: connection.to)
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .allowsHitTesting(false)
                }
                if let marquee {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.6)))
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(.named("board"))
            .clipped()
            .overlay(alignment: .top) {
                if let id = model.selectedEdge, let edge = model.canvas.edges.first(where: { $0.id == id }) {
                    EdgeInspector(model: model, edge: edge).padding(10)
                } else if model.selection.count == 1, let id = model.selection.first, let node = model.canvas.node(id), node.kind == .group {
                    GroupInspector(model: model, node: node).padding(10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showMinimap, !model.canvas.nodes.isEmpty {
                    CanvasMinimap(model: model).padding(12)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(Int((model.scale * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.regularMaterial, in: .capsule)
                    .padding(12)
                    .onTapGesture { model.zoomToActualSize() }
                    .help("Zoom: pinch or ⌘-scroll. Click for 100%.")
            }
            .background(WindowReader { events.window = $0 })
            .onAppear {
                model.viewSize = geometry.size
                events.frame = geometry.frame(in: .global)
                events.install(model: model)
                if model.canvas.nodes.isEmpty == false, model.scale == 1, model.offset == CGPoint(x: 80, y: 80) { model.fit() }
            }
            .onDisappear { events.remove() }
            .onChange(of: geometry.size) { _, size in
                model.viewSize = size
                events.frame = geometry.frame(in: .global)
            }
            .onChange(of: geometry.frame(in: .global)) { _, frame in events.frame = frame }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard model.editingText == nil else { return .ignored }
                model.deleteSelection()
                return .handled
            }
            .onKeyPress(.escape) {
                model.selection = []
                model.selectedEdge = nil
                return .handled
            }
            .onKeyPress(characters: ["a"], phases: .down) { press in
                guard press.modifiers.contains(.command), model.editingText == nil else { return .ignored }
                model.selection = Set(model.canvas.nodes.map(\.id))
                return .handled
            }
            .onDrop(of: [.fileURL, .utf8PlainText, .plainText], isTargeted: nil) { providers, location in
                drop(providers, at: location)
            }
        }
        .background(Color(theme.editor.background))
    }

    // MARK: Background: grid, marquee, panning

    private var background: some View {
        Canvas { context, size in
            let step = CanvasEditing.grid * model.scale
            guard step >= 6 else { return }
            let dot = Color.secondary.opacity(snapToGrid ? 0.25 : 0.12)
            var x = model.offset.x.truncatingRemainder(dividingBy: step)
            if x < 0 { x += step }
            while x < size.width {
                var y = model.offset.y.truncatingRemainder(dividingBy: step)
                if y < 0 { y += step }
                while y < size.height {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)), with: .color(dot))
                    y += step
                }
                x += step
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("board"))
                .onChanged { value in
                    if NSEvent.modifierFlags.contains(.option) || panStart != nil {
                        // ⌥-drag pans, for a mouse without a scroll wheel.
                        if panStart == nil { panStart = model.offset }
                        model.offset = CGPoint(x: panStart!.x + value.translation.width, y: panStart!.y + value.translation.height)
                        return
                    }
                    marquee = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                     width: abs(value.translation.width), height: abs(value.translation.height))
                }
                .onEnded { _ in
                    defer { marquee = nil; panStart = nil }
                    guard let marquee else { return }
                    let a = model.world(marquee.origin)
                    let rect = CanvasRect(x: a.x, y: a.y, width: marquee.width / model.scale, height: marquee.height / model.scale)
                    let hits = Set(CanvasEditing.nodes(in: rect, of: model.canvas))
                    model.selection = NSEvent.modifierFlags.contains(.shift) ? model.selection.union(hits) : hits
                    model.selectedEdge = nil
                }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2, coordinateSpace: .named("board")).onEnded { value in
                let p = model.world(value.location)
                model.addText(at: CanvasRect(x: CanvasEditing.snap(p.x - 130), y: CanvasEditing.snap(p.y - 40), width: 260, height: 120))
            }
        )
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named("board")).onEnded { value in
                focused = true
                model.editingText = nil
                if let edge = CanvasEdgesLayer.edge(at: value.location, model: model) {
                    model.selectedEdge = edge
                    model.selection = []
                } else {
                    model.selectedEdge = nil
                    if !NSEvent.modifierFlags.contains(.shift) { model.selection = [] }
                }
            }
        )
    }

    // MARK: Nodes

    /// A node at its place on the board, scaled, with selection, handles and gestures.
    private func nodeView<Content: View>(_ node: CanvasNode, @ViewBuilder content: () -> Content) -> some View {
        let frame = model.viewRect(node.rect)
        let selected = model.selection.contains(node.id)
        let editing = model.editingText == node.id
        return content()
            .frame(width: node.rect.width, height: node.rect.height, alignment: .topLeading)
            .scaleEffect(model.scale, anchor: .topLeading)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8 * model.scale + 2)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected, !editing { resizeHandle(node) }
            }
            .overlay {
                if (selected || hovered == node.id), !editing, node.kind != .group || selected {
                    connectDots(node, size: frame.size)
                }
            }
            .onHover { inside in hovered = inside ? node.id : (hovered == node.id ? nil : hovered) }
            .gesture(editing ? nil : moveGesture(node))
            .simultaneousGesture(TapGesture(count: 2).onEnded { open(node) })
            .simultaneousGesture(TapGesture().onEnded { select(node) })
            .contextMenu { CanvasContextMenu(session: session, model: model, node: node) }
            .offset(x: frame.minX, y: frame.minY)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityName(node))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ node: CanvasNode) {
        focused = model.editingText == nil
        model.selectedEdge = nil
        if NSEvent.modifierFlags.contains(.shift) {
            if model.selection.contains(node.id) { model.selection.remove(node.id) } else { model.selection.insert(node.id) }
        } else if !model.selection.contains(node.id) || model.selection.count > 1 {
            model.selection = [node.id]
        }
        if model.editingText != nil, model.editingText != node.id { model.editingText = nil }
    }

    private func open(_ node: CanvasNode) {
        switch node.card {
        case .text: model.editingText = node.id
        case .note(let path): session.open(path)
        case .scene(_, let sceneID): session.open(sceneID: sceneID)
        case .link(let url): if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        case .image(let path), .file(let path):
            if let url = try? session.store.url(for: path) { NSWorkspace.shared.open(url) }
        case .group, .unknown: break
        }
    }

    private func moveGesture(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("board"))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = model.canvas
                    if !model.selection.contains(node.id) {
                        model.selection = NSEvent.modifierFlags.contains(.shift) ? model.selection.union([node.id]) : [node.id]
                    }
                    model.selectedEdge = nil
                    model.beginInteraction()
                }
                guard let start = dragStart else { return }
                let ids = CanvasEditing.carried(model.selection, in: start)
                model.update(CanvasEditing.moving(ids, by: value.translation.width / model.scale, value.translation.height / model.scale,
                                                  in: start, snapToGrid: snapToGrid))
            }
            .onEnded { _ in
                dragStart = nil
                model.endInteraction("Move")
            }
    }

    private func resizeHandle(_ node: CanvasNode) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Color.accentColor, in: .rect(cornerRadius: 4))
            .offset(x: 6, y: 6)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("board"))
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = model.canvas
                            model.beginInteraction()
                        }
                        guard let start = dragStart, let original = start.node(node.id)?.rect else { return }
                        var rect = original
                        rect.width += value.translation.width / model.scale
                        rect.height += value.translation.height / model.scale
                        model.update(CanvasEditing.resizing(node.id, to: rect, in: start, snapToGrid: snapToGrid))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        model.endInteraction("Resize")
                    }
            )
            .help("Drag to resize")
    }

    /// Dots on each side: drag one to another card to connect them.
    private func connectDots(_ node: CanvasNode, size: CGSize) -> some View {
        ZStack {
            ForEach(CanvasEdge.Side.allCases, id: \.self) { side in
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .position(dotPosition(side, size))
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("board"))
                            .onChanged { value in connection = (node.id, side, value.location) }
                            .onEnded { value in
                                defer { connection = nil }
                                guard let target = model.node(at: value.location), target.id != node.id else { return }
                                let toSide = CanvasEditing.sides(from: node.rect, to: target.rect).1
                                if let (connected, id) = CanvasEditing.connecting(node.id, to: target.id, fromSide: side, toSide: toSide, in: model.canvas) {
                                    model.apply(connected, "Connect")
                                    model.selectedEdge = id
                                    model.selection = []
                                }
                            }
                    )
                    .help("Drag to another card to connect")
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func dotPosition(_ side: CanvasEdge.Side, _ size: CGSize) -> CGPoint {
        switch side {
        case .top: CGPoint(x: size.width / 2, y: 0)
        case .bottom: CGPoint(x: size.width / 2, y: size.height)
        case .left: CGPoint(x: 0, y: size.height / 2)
        case .right: CGPoint(x: size.width, y: size.height / 2)
        }
    }

    private func accessibilityName(_ node: CanvasNode) -> String {
        switch node.card {
        case .text: "Text card: " + String(node.text.prefix(80))
        case .note(let path): "Note card: " + (session.links.graph.note(at: path)?.name ?? path)
        case .scene(_, let id): "Scene card " + id
        case .image(let path): "Image " + (path as NSString).lastPathComponent
        case .link(let url): "Link " + url
        case .group: "Group " + (node.label ?? "")
        case .file(let path): "File " + path
        case .unknown(let type): "Card of type " + type
        }
    }

    // MARK: Drop

    private func drop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let point = model.world(location)
        var handled = false
        for (index, provider) in providers.enumerated() {
            let rect = CanvasRect(x: CanvasEditing.snap(point.x + Double(index) * 30 - 130), y: CanvasEditing.snap(point.y + Double(index) * 30 - 60),
                                  width: 260, height: 160)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in CanvasDrops.addFile(url, at: rect, session: session, model: model) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string else { return }
                    Task { @MainActor in CanvasDrops.addPayload(string, at: rect, session: session, model: model) }
                }
            }
        }
        return handled
    }
}

/// What dropping something on a canvas does.
@MainActor
enum CanvasDrops {
    /// Payloads from Slate's own sidebars.
    static func addPayload(_ string: String, at rect: CanvasRect, session: ProjectSession, model: CanvasModel) {
        let canvas = model.canvas
        if string.hasPrefix("slate-note:") {
            model.add(CanvasEditing.fileCard(String(string.dropFirst(11)), at: CanvasRect(x: rect.x, y: rect.y, width: 280, height: 220), in: canvas), "Add Note Card")
        } else if string.hasPrefix("slate-scene:"), let hash = string.lastIndex(of: "#") {
            let file = String(string[string.index(string.startIndex, offsetBy: 12)..<hash])
            let id = String(string[hash...])
            model.add(CanvasEditing.fileCard(file, subpath: id, at: CanvasRect(x: rect.x, y: rect.y, width: 300, height: 120), in: canvas), "Add Scene Card")
        } else if string.hasPrefix("slate-heading:") {
            model.add(CanvasEditing.textCard("## " + string.dropFirst(14), at: CanvasRect(x: rect.x, y: rect.y, width: 260, height: 80), in: canvas), "Add Heading")
        } else if let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme, ["http", "https"].contains(scheme) {
            model.add(CanvasEditing.linkCard(url.absoluteString, at: CanvasRect(x: rect.x, y: rect.y, width: 260, height: 80), in: canvas), "Add Link")
        } else if !string.isEmpty {
            model.add(CanvasEditing.textCard(string, at: rect, in: canvas), "Add Text Card")
        }
    }

    /// A file from Finder: images are copied into the project; project notes become note cards.
    static func addFile(_ url: URL, at rect: CanvasRect, session: ProjectSession, model: CanvasModel) {
        let root = session.store.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            let relative = String(path.dropFirst(root.count + 1))
            model.add(CanvasEditing.fileCard(relative, at: rect, in: model.canvas), "Add Card")
            return
        }
        guard CanvasCard.imageExtensions.contains(url.pathExtension.lowercased()) else {
            SlateAppModel.showError("Only images can be dropped from outside the project", CocoaError(.fileReadUnsupportedScheme))
            return
        }
        if let relative = importImage(url, session: session) {
            var size = CGSize(width: 260, height: 180)
            if let image = NSImage(contentsOf: url), image.size.width > 0 {
                size = CGSize(width: 300, height: (300 * image.size.height / image.size.width).rounded())
            }
            model.add(CanvasEditing.fileCard(relative, at: CanvasRect(x: rect.x, y: rect.y, width: size.width, height: size.height), in: model.canvas), "Add Image")
        }
    }

    /// Copies an image to `universe/canvases/images/`, returning its project path.
    /// Copies an image into the project (`folder`, numbered if the name is taken).
    static func importImage(_ url: URL, session: ProjectSession, folder: String = "universe/canvases/images") -> String? {
        let ext = url.pathExtension.lowercased()
        let stem = Slug.make(url.deletingPathExtension().lastPathComponent)
        var name = "\(stem).\(ext)"
        var counter = 2
        let existing = Set(session.allPaths)
        while existing.contains("\(folder)/\(name)") {
            name = "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        do {
            let data = try Data(contentsOf: url)
            try CoordinatedFileIO.write(data, to: try session.store.url(for: "\(folder)/\(name)"))
            session.store.rescan()
            return "\(folder)/\(name)"
        } catch {
            SlateAppModel.showError("Couldn't copy the image", error)
            return nil
        }
    }
}

// MARK: - Edges

struct CanvasEdgesLayer: View {
    let model: CanvasModel
    let connector: Color

    var body: some View {
        Canvas { context, _ in
            for edge in model.canvas.edges {
                guard let curve = Self.curve(edge, model: model) else { continue }
                let selected = model.selectedEdge == edge.id
                let color = selected ? Color.accentColor : (CanvasColor.color(edge.color) ?? connector)
                let width = (selected ? 3 : 2) * max(min(model.scale, 1.5), 0.6)
                var path = Path()
                path.move(to: curve.0)
                path.addCurve(to: curve.3, control1: curve.1, control2: curve.2)
                context.stroke(path, with: .color(color), lineWidth: width)
                if edge.toArrow { context.fill(Self.arrow(at: curve.3, from: curve.2, size: 10 * max(min(model.scale, 1.5), 0.6)), with: .color(color)) }
                if edge.fromArrow { context.fill(Self.arrow(at: curve.0, from: curve.1, size: 10 * max(min(model.scale, 1.5), 0.6)), with: .color(color)) }
                if let label = edge.label, !label.isEmpty {
                    let mid = Self.point(on: curve, at: 0.5)
                    let text = context.resolve(Text(label).font(.system(size: 12 * min(max(model.scale, 0.6), 1.4))).foregroundStyle(color))
                    let size = text.measure(in: CGSize(width: 240, height: 60))
                    let box = CGRect(x: mid.x - size.width / 2 - 5, y: mid.y - size.height / 2 - 2, width: size.width + 10, height: size.height + 4)
                    context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Color(nsColor: .windowBackgroundColor)))
                    context.draw(text, in: box.insetBy(dx: 5, dy: 2))
                }
            }
        }
    }

    typealias Curve = (CGPoint, CGPoint, CGPoint, CGPoint)

    /// The edge as a cubic curve in view coordinates.
    static func curve(_ edge: CanvasEdge, model: CanvasModel) -> Curve? {
        guard let from = model.canvas.node(edge.fromNode), let to = model.canvas.node(edge.toNode) else { return nil }
        let auto = CanvasEditing.sides(from: from.rect, to: to.rect)
        let fromSide = edge.fromSide ?? auto.0, toSide = edge.toSide ?? auto.1
        let a = CanvasEditing.anchor(from.rect, fromSide), b = CanvasEditing.anchor(to.rect, toSide)
        let start = model.view(a.x, a.y), end = model.view(b.x, b.y)
        let reach = max(40 * model.scale, hypot(end.x - start.x, end.y - start.y) * 0.35)
        return (start, push(start, fromSide, reach), push(end, toSide, reach), end)
    }

    private static func push(_ point: CGPoint, _ side: CanvasEdge.Side, _ by: Double) -> CGPoint {
        switch side {
        case .top: CGPoint(x: point.x, y: point.y - by)
        case .bottom: CGPoint(x: point.x, y: point.y + by)
        case .left: CGPoint(x: point.x - by, y: point.y)
        case .right: CGPoint(x: point.x + by, y: point.y)
        }
    }

    static func point(on c: Curve, at t: Double) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * c.0.x + 3 * u * u * t * c.1.x + 3 * u * t * t * c.2.x + t * t * t * c.3.x
        let y = u * u * u * c.0.y + 3 * u * u * t * c.1.y + 3 * u * t * t * c.2.y + t * t * t * c.3.y
        return CGPoint(x: x, y: y)
    }

    private static func arrow(at tip: CGPoint, from control: CGPoint, size: Double) -> Path {
        let angle = atan2(tip.y - control.y, tip.x - control.x)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - size * cos(angle - .pi / 7), y: tip.y - size * sin(angle - .pi / 7)))
        path.addLine(to: CGPoint(x: tip.x - size * cos(angle + .pi / 7), y: tip.y - size * sin(angle + .pi / 7)))
        path.closeSubpath()
        return path
    }

    /// The edge under a view point (within 6 pt of its curve or on its label).
    static func edge(at point: CGPoint, model: CanvasModel) -> String? {
        for edge in model.canvas.edges.reversed() {
            guard let curve = curve(edge, model: model) else { continue }
            for step in 0...30 {
                let p = Self.point(on: curve, at: Double(step) / 30)
                if hypot(p.x - point.x, p.y - point.y) < 7 { return edge.id }
            }
        }
        return nil
    }
}

/// Label, colour and arrows for the selected connection.
private struct EdgeInspector: View {
    let model: CanvasModel
    let edge: CanvasEdge
    @State private var label = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit(commitLabel)
            ColorMenu(selected: edge.color) { color in
                let id = edge.id
                model.edit("Colour") { CanvasEditing.updatingEdge(id, in: $0) { $0.color = color } }
            }
            Toggle("Start arrow", isOn: Binding(get: { edge.fromArrow }, set: { value in
                let id = edge.id
                model.edit("Arrow") { CanvasEditing.updatingEdge(id, in: $0) { $0.fromArrow = value } }
            }))
            Toggle("End arrow", isOn: Binding(get: { edge.toArrow }, set: { value in
                let id = edge.id
                model.edit("Arrow") { CanvasEditing.updatingEdge(id, in: $0) { $0.toArrow = value } }
            }))
            Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
                .help("Delete the connection")
        }
        .toggleStyle(.checkbox)
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .onAppear { label = edge.label ?? "" }
        .onChange(of: edge.id) { label = edge.label ?? "" }
        .onDisappear(perform: commitLabel)
    }

    private func commitLabel() {
        guard label != (edge.label ?? "") else { return }
        let id = edge.id, text = label
        model.edit("Label") { CanvasEditing.updatingEdge(id, in: $0) { $0.label = text } }
    }
}

/// The label of the selected group.
private struct GroupInspector: View {
    let model: CanvasModel
    let node: CanvasNode
    @State private var label = ""

    var body: some View {
        HStack {
            Image(systemName: "rectangle.dashed")
            TextField("Group name", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit(commit)
        }
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .onAppear { label = node.label ?? "" }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard label != (node.label ?? "") else { return }
        let id = node.id, text = label
        model.edit("Rename Group") { CanvasEditing.updating(id, in: $0) { $0.label = text.isEmpty ? nil : text } }
    }
}

struct ColorMenu: View {
    let selected: String?
    let set: (String?) -> Void

    var body: some View {
        Menu {
            Button("No Colour") { set(nil) }
            ForEach(CanvasColor.presets, id: \.id) { preset in
                Button {
                    set(preset.id)
                } label: {
                    Label(preset.name, systemImage: selected == preset.id ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        } label: {
            Label("Colour", systemImage: "paintpalette")
        }
        .fixedSize()
    }
}

// MARK: - Minimap

struct CanvasMinimap: View {
    let model: CanvasModel
    static let size = CGSize(width: 200, height: 130)

    var body: some View {
        let visible = model.visibleWorld
        let world = (model.canvas.bounds ?? visible).union(visible)
        let fit = min(Self.size.width / max(world.width, 1), Self.size.height / max(world.height, 1))
        Canvas { context, _ in
            func rect(_ r: CanvasRect) -> CGRect {
                CGRect(x: (r.x - world.x) * fit, y: (r.y - world.y) * fit, width: max(r.width * fit, 2), height: max(r.height * fit, 2))
            }
            for node in model.canvas.nodes {
                let color = CanvasColor.color(node.color) ?? .secondary
                if node.kind == .group {
                    context.stroke(Path(rect(node.rect)), with: .color(color.opacity(0.5)), lineWidth: 1)
                } else {
                    context.fill(Path(rect(node.rect)), with: .color(color.opacity(model.selection.contains(node.id) ? 0.9 : 0.45)))
                }
            }
            context.stroke(Path(rect(visible)), with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .padding(6)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                model.centre(on: world.x + (value.location.x - 6) / fit, world.y + (value.location.y - 6) / fit)
            }
        )
        .help("Click or drag to move around the canvas")
        .accessibilityLabel("Minimap")
    }
}

// MARK: - Context menu and toolbar

private struct CanvasContextMenu: View {
    let session: ProjectSession
    let model: CanvasModel
    let node: CanvasNode

    var body: some View {
        let ids = model.selection.contains(node.id) ? model.selection : [node.id]
        if case .text = node.card { Button("Edit Text") { model.editingText = node.id } }
        if case .note(let path) = node.card { Button("Open Note") { session.open(path) } }
        if case .scene(_, let id) = node.card { Button("Go to Scene") { session.open(sceneID: id) } }
        ColorMenu(selected: node.color) { color in
            model.edit("Colour") { canvas in
                ids.reduce(canvas) { result, id in CanvasEditing.updating(id, in: result) { $0.color = color } }
            }
        }
        Button("Group") {
            model.selection = ids
            model.groupSelection()
        }
        Button("Bring to Front") { model.edit("Bring to Front") { CanvasEditing.bringingToFront(ids, in: $0) } }
        Divider()
        Button("Delete", role: .destructive) {
            model.selection = ids
            model.deleteSelection()
        }
    }
}

struct CanvasToolbar: ToolbarContent {
    let session: ProjectSession
    let model: CanvasModel
    @AppStorage("canvasSnapToGrid") private var snapToGrid = true
    @AppStorage("canvasShowMinimap") private var showMinimap = true
    @State private var askingForLink = false
    @State private var linkText = ""

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button("Text Card") { model.addText() }
                Button("Group") { model.groupSelection() }
                Menu("Note") {
                    ForEach(session.links.graph.notes.filter { $0.path.hasPrefix(ProjectLayout.universe + "/") }) { note in
                        Button(note.name) {
                            model.add(CanvasEditing.fileCard(note.path, at: model.newCardRect(width: 280, height: 220), in: model.canvas), "Add Note Card")
                        }
                    }
                }
                Menu("Scene") {
                    ForEach(session.script.book.scenes) { scene in
                        if let id = scene.scene.sceneID {
                            Button("\(scene.number). \(scene.scene.heading)") {
                                model.add(CanvasEditing.fileCard(scene.file, subpath: "#" + id, at: model.newCardRect(width: 300, height: 120), in: model.canvas), "Add Scene Card")
                            }
                        }
                    }
                }
                Button("Image…") { chooseImage() }
                Button("Web Link…") { askingForLink = true }
            } label: {
                Label("Add", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("Add a card (or drag notes, scenes and images onto the canvas)")

            Menu {
                Section("Align") {
                    Button("Left") { align(.left) }
                    Button("Centre") { align(.centerX) }
                    Button("Right") { align(.right) }
                    Button("Top") { align(.top) }
                    Button("Middle") { align(.centerY) }
                    Button("Bottom") { align(.bottom) }
                }
                Section("Distribute") {
                    Button("Horizontally") { model.edit("Distribute") { CanvasEditing.distributing(model.selection, .horizontal, in: $0) } }
                        .disabled(model.selection.count < 3)
                    Button("Vertically") { model.edit("Distribute") { CanvasEditing.distributing(model.selection, .vertical, in: $0) } }
                        .disabled(model.selection.count < 3)
                }
            } label: {
                Label("Arrange", systemImage: "align.horizontal.left")
            }
            .disabled(model.selection.count < 2)
            .help("Align or distribute the selected cards")

            Toggle(isOn: $snapToGrid) { Label("Snap to Grid", systemImage: "grid") }
                .help("Snap cards to a 20-point grid")
            Toggle(isOn: $showMinimap) { Label("Minimap", systemImage: "map") }
                .help("Show the minimap")

            Button { model.zoom(by: 1 / 1.25) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .keyboardShortcut("-")
            Button { model.zoom(by: 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .keyboardShortcut("=")
            Button { model.fit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .keyboardShortcut("0")
                .help("Fit everything (⌘0); ⇧⌘0 for 100%")
            Button { model.zoomToActualSize() } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
                .keyboardShortcut("0", modifiers: [.command, .shift])
        }
        ToolbarItem {
            Color.clear.frame(width: 0, height: 0)
                .alert("Add a Web Link", isPresented: $askingForLink) {
                    TextField("https://…", text: $linkText)
                    Button("Add") {
                        let url = linkText.trimmingCharacters(in: .whitespaces)
                        if !url.isEmpty {
                            model.add(CanvasEditing.linkCard(url, at: model.newCardRect(width: 260, height: 80), in: model.canvas), "Add Link")
                        }
                        linkText = ""
                    }
                    Button("Cancel", role: .cancel) { linkText = "" }
                }
        }
    }

    private func align(_ alignment: CanvasEditing.Alignment) {
        model.edit("Align") { CanvasEditing.aligning(model.selection, alignment, in: $0) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for (index, url) in panel.urls.enumerated() {
            var rect = model.newCardRect(width: 300, height: 200)
            rect.x += Double(index) * 30
            rect.y += Double(index) * 30
            CanvasDrops.addFile(url, at: rect, session: session, model: model)
        }
    }
}

// MARK: - Trackpad and mouse wheel

/// Pans on scroll and zooms on pinch or ⌘-scroll while the pointer is over
/// the board. (SwiftUI has no scroll-wheel events for a custom view.)
/// A board that pans and zooms (the canvas, a map).
@MainActor
protocol ZoomPanTarget: AnyObject {
    func zoom(by factor: Double, around anchor: CGPoint?)
    func pan(by dx: Double, _ dy: Double)
}

extension CanvasModel: ZoomPanTarget {}

@MainActor
final class CanvasEventMonitor {
    weak var window: NSWindow?
    /// The board in window coordinates, top-left origin.
    var frame: CGRect = .zero
    private var monitor: Any?

    func install(model: any ZoomPanTarget) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self, weak model] event in
            // NSEvent isn't Sendable: read what's needed, then decide on the main actor.
            let type = event.type
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            let magnification = type == .magnify ? event.magnification : 0
            let precise = type == .scrollWheel ? event.hasPreciseScrollingDeltas : false
            let dx = type == .scrollWheel ? event.scrollingDeltaX : 0
            let dy = type == .scrollWheel ? event.scrollingDeltaY : 0
            let zoomKey = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let model, let window = self.window, window.windowNumber == windowNumber,
                      let content = window.contentView else { return false }
                let point = CGPoint(x: location.x, y: content.bounds.height - location.y)
                guard self.frame.contains(point) else { return false }
                let local = CGPoint(x: point.x - self.frame.minX, y: point.y - self.frame.minY)
                if type == .magnify {
                    model.zoom(by: 1 + magnification, around: local)
                } else if zoomKey {
                    model.zoom(by: exp(dy * (precise ? 0.01 : 0.1)), around: local)
                } else {
                    let factor = precise ? 1.0 : 10.0
                    model.pan(by: dx * factor, dy * factor)
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Hands back the hosting window.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in found(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in found(view?.window) }
    }
}
