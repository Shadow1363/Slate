import AppKit
import SlateCore
import SwiftUI
import UniformTypeIdentifiers

/// Asks an open map to point out an item ("Show on Map").
struct MapRevealRequest: Equatable {
    let path: String
    let item: String
}

/// A `*.map.json` file in the Universe area.
struct MapPane: View {
    let session: ProjectSession
    let document: TextDocument
    @State private var model: MapModel
    @Environment(\.undoManager) private var undoManager

    init(session: ProjectSession, document: TextDocument) {
        self.session = session
        self.document = document
        _model = State(initialValue: MapModel(document: document, store: session.store))
    }

    var body: some View {
        VStack(spacing: 0) {
            DiskStateBanners(store: session.store, document: document, close: { session.universeSelection = nil })
            if let error = model.file.parseError {
                Banner(systemImage: "exclamationmark.triangle.fill", message: "This map can't be read: \(error) Fix the file and it reloads.") {}
                DocumentEditor(store: session.store, document: document, close: { session.universeSelection = nil })
            } else {
                if model.map.image != nil, model.image == nil {
                    Banner(systemImage: "photo.badge.exclamationmark", message: "The map image “\(model.map.image ?? "")” is missing. Pins stay where they are.") {
                        Button("Choose Image…") { MapActions.chooseImage(session: session, model: model) }
                    }
                }
                if model.tool == .region || model.tool == .path {
                    Banner(systemImage: model.tool.symbol, message: "Click to add corners. Double-click or press Return to finish, Escape to stop.") {
                        Button("Done") { model.finishDraft() }.disabled(model.draft.count < (model.tool == .region ? 3 : 2))
                    }
                }
                HSplitView {
                    MapBoard(session: session, model: model)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    if let id = model.selection, let item = model.map.item(id) {
                        MapInspector(session: session, model: model, item: item)
                            .id(id)
                            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle(Self.title(document.relativePath))
        .toolbar { MapToolbar(session: session, model: model) }
        .onAppear {
            model.file.undoManager = undoManager
            takeReveal()
        }
        .onChange(of: document.text) {
            model.file.documentChanged()
            model.reloadImage(store: session.store)
        }
        .onChange(of: session.mapReveal) { takeReveal() }
        .onChange(of: session.store.files) { model.reloadImage(store: session.store, force: model.image == nil) }
        .onDisappear { model.file.flush() }
    }

    private func takeReveal() {
        guard let request = session.mapReveal, request.path == document.relativePath else { return }
        session.mapReveal = nil
        if let item = model.map.item(request.item), let layer = item.layer { model.hiddenLayers.remove(layer) }
        model.selection = request.item
        model.highlighted = request.item
        DispatchQueue.main.async { model.centre(on: request.item) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { model.highlighted = nil }
    }

    /// `universe/maps/city.map.json` → `city`.
    static func title(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(MapFile.suffix) ? String(name.dropLast(MapFile.suffix.count)) : name
    }
}

// MARK: - The board

struct MapBoard: View {
    /// Big enough to fit a map into (the first layout pass can be a few points wide).
    static func hasRoom(_ size: CGSize) -> Bool { size.width > 200 && size.height > 150 }

    let session: ProjectSession
    @Bindable var model: MapModel
    @Environment(\.slateTheme) private var theme
    @FocusState private var focused: Bool
    @State private var events = CanvasEventMonitor()
    @State private var drag: (start: CGPoint, item: String?, last: CGPoint)?
    @State private var vertexDrag: Int?
    @State private var pulse = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                base
                MapShapes(model: model, theme: theme, pulse: pulse)
                    .allowsHitTesting(false)
                ForEach(model.visibleItems.filter { $0.kind == .pin }) { pin in
                    MapPinView(item: pin, selected: model.selection == pin.id, highlighted: model.highlighted == pin.id,
                               color: CanvasColor.color(pin.color) ?? Color(theme.canvas.pin), scale: model.scale)
                        .position(model.view(pin.points[0]))
                        .offset(y: -14)
                        .allowsHitTesting(false)
                }
                if let id = model.selection, let item = model.map.item(id), item.kind != .pin, model.isVisible(item) {
                    ForEach(Array(item.points.enumerated()), id: \.offset) { index, point in
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                            .frame(width: 11, height: 11)
                            .position(model.view(point))
                            .gesture(vertexGesture(item: id, index: index))
                            .help("Drag to move this corner")
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(.named("map"))
            .clipped()
            .contentShape(Rectangle())
            .gesture(boardDrag)
            .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named("map")).onEnded { value in
                if model.tool == .region || model.tool == .path {
                    model.finishDraft()
                } else if model.tool == .select, let item = model.item(at: value.location) {
                    open(item)
                }
            })
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("map")).onEnded { value in tap(at: value.location) })
            .overlay(alignment: .bottomLeading) {
                Text("\(Int((model.scale * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.regularMaterial, in: .capsule)
                    .padding(12)
                    .onTapGesture { model.fit() }
                    .help("Zoom: pinch or ⌘-scroll. Click to fit.")
            }
            .background(WindowReader { events.window = $0 })
            .onAppear {
                model.viewSize = geometry.size
                events.frame = geometry.frame(in: .global)
                events.install(model: model)
                // The first layout can report a sliver of a size; fit once there's room.
                if !model.hasFitted, Self.hasRoom(geometry.size) {
                    model.hasFitted = true
                    model.fit()
                }
            }
            .onDisappear { events.remove() }
            .onChange(of: geometry.size) { _, size in
                model.viewSize = size
                events.frame = geometry.frame(in: .global)
                if !model.hasFitted, Self.hasRoom(size) {
                    model.hasFitted = true
                    model.fit()
                }
            }
            .onChange(of: geometry.frame(in: .global)) { _, frame in events.frame = frame }
            .onChange(of: model.highlighted) { _, id in
                guard id != nil else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatCount(4, autoreverses: true)) { pulse.toggle() }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                model.deleteSelection()
                return .handled
            }
            .onKeyPress(.return) {
                guard !model.draft.isEmpty else { return .ignored }
                model.finishDraft()
                return .handled
            }
            .onKeyPress(.escape) {
                if model.tool != .select { model.tool = .select } else { model.selection = nil }
                return .handled
            }
            .onDrop(of: [.fileURL, .utf8PlainText, .plainText], isTargeted: nil) { providers, location in
                MapActions.drop(providers, at: location, session: session, model: model)
            }
        }
        .background(Color(theme.editor.background))
    }

    /// The image, or a grid when the map has none.
    private var base: some View {
        let rect = model.mapRect
        return ZStack(alignment: .topLeading) {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            } else {
                Canvas { context, _ in
                    context.fill(Path(rect), with: .color(Color.primary.opacity(0.04)))
                    let step = max(rect.width / 24, 4)
                    var path = Path()
                    var x = rect.minX
                    while x <= rect.maxX + 0.5 {
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY))
                        x += step
                    }
                    var y = rect.minY
                    while y <= rect.maxY + 0.5 {
                        path.move(to: CGPoint(x: rect.minX, y: y))
                        path.addLine(to: CGPoint(x: rect.maxX, y: y))
                        y += step
                    }
                    context.stroke(path, with: .color(Color.secondary.opacity(0.18)), lineWidth: 0.5)
                    context.stroke(Path(rect), with: .color(Color.secondary.opacity(0.4)), lineWidth: 1)
                }
            }
        }
    }

    private func tap(at location: CGPoint) {
        focused = true
        switch model.tool {
        case .select:
            model.selection = model.item(at: location)?.id
        case .pin:
            guard model.mapRect.contains(location) else { return }
            model.addPin(at: location)
            model.tool = .select
        case .region, .path:
            guard model.mapRect.contains(location) else { return }
            model.draft.append(model.mapPoint(location).clamped)
        }
    }

    private func open(_ item: MapItem) {
        let graph = session.links.graph
        if let note = item.note, let path = graph.resolve(note)?.path {
            session.open(path)
        } else if let scene = item.scenes.first {
            session.open(sceneID: scene)
        }
    }

    /// Drag an item to move it; drag empty space to pan.
    private var boardDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("map"))
            .onChanged { value in
                if drag == nil {
                    let hit = model.tool == .select ? model.item(at: value.startLocation) : nil
                    if let hit { model.selection = hit.id }
                    drag = (value.startLocation, hit?.id, value.startLocation)
                }
                guard var current = drag else { return }
                if let id = current.item {
                    let size = model.size
                    let dx = (value.location.x - current.last.x) / (size.width * model.scale)
                    let dy = (value.location.y - current.last.y) / (size.height * model.scale)
                    model.file.update(MapEditing.moving([id], by: dx, dy, in: model.map))
                } else {
                    model.pan(by: value.location.x - current.last.x, value.location.y - current.last.y)
                }
                current.last = value.location
                drag = current
            }
            .onEnded { _ in
                if drag?.item != nil { model.file.endInteraction("Move") }
                drag = nil
            }
    }

    private func vertexGesture(item id: String, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("map"))
            .onChanged { value in
                model.file.update(MapEditing.movingPoint(index, of: id, to: model.mapPoint(value.location), in: model.map))
            }
            .onEnded { _ in model.file.endInteraction("Move Corner") }
    }
}

/// Regions, paths, their labels, and the shape being drawn.
private struct MapShapes: View {
    let model: MapModel
    let theme: ResolvedTheme
    let pulse: Bool

    var body: some View {
        Canvas { context, _ in
            let fallback = Color(theme.canvas.pin)
            for item in model.map.regions + model.map.paths where model.isVisible(item) {
                let points = item.points.map(model.view)
                guard points.count >= 2 else { continue }
                let color = CanvasColor.color(item.color) ?? fallback
                let selected = model.selection == item.id
                let glow = model.highlighted == item.id && pulse
                var path = Path()
                path.addLines(points)
                if item.kind == .region {
                    path.closeSubpath()
                    context.fill(path, with: .color(color.opacity(glow ? 0.45 : 0.2)))
                    context.stroke(path, with: .color(selected ? Color.accentColor : color), lineWidth: selected ? 2.5 : 1.5)
                } else {
                    context.stroke(path, with: .color(selected ? Color.accentColor : color),
                                   style: StrokeStyle(lineWidth: glow ? 6 : selected ? 4 : 3, lineCap: .round, lineJoin: .round, dash: [9, 5]))
                }
                if !item.title.isEmpty, model.scale > 0.15 {
                    let anchor = item.kind == .region ? model.view(MapGeometry.centre(item.points)) : points[points.count / 2]
                    let label = Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                    context.draw(label, at: CGPoint(x: anchor.x, y: anchor.y + (item.kind == .path ? -12 : 0)))
                }
            }
            if !model.draft.isEmpty {
                var path = Path()
                path.addLines(model.draft.map(model.view))
                if model.tool == .region, model.draft.count > 2 { path.closeSubpath() }
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                for point in model.draft.map(model.view) {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.accentColor))
                }
            }
        }
        .accessibilityChildren {
            ForEach(model.map.regions + model.map.paths) { item in
                if model.isVisible(item) {
                    Rectangle()
                        .accessibilityLabel("\(item.kind == .region ? "Region" : "Path"): \(item.title.isEmpty ? "untitled" : item.title)")
                        .accessibilityAddTraits(model.selection == item.id ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { model.selection = item.id }
                }
            }
        }
    }
}

private struct MapPinView: View {
    let item: MapItem
    let selected: Bool
    let highlighted: Bool
    let color: Color
    let scale: Double

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, color)
                .shadow(radius: selected ? 3 : 1)
                .scaleEffect(highlighted ? 1.5 : selected ? 1.2 : 1)
                .animation(.spring(duration: 0.3), value: highlighted)
            if !item.title.isEmpty, scale > 0.15 {
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.regularMaterial, in: .capsule)
                    .fixedSize()
            }
        }
        .overlay {
            if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: 30, height: 30).offset(y: -9) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pin: \(item.title)")
    }
}

// MARK: - Actions

@MainActor
enum MapActions {
    static func chooseImage(session: ProjectSession, model: MapModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a map image. It's copied into the project; pins keep their places if you swap it later."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setImage(url, session: session, model: model)
    }

    static func setImage(_ url: URL, session: ProjectSession, model: MapModel) {
        let folder = (model.path as NSString).deletingLastPathComponent
        guard let copied = CanvasDrops.importImage(url, session: session, folder: folder) else { return }
        let name = String(copied.dropFirst(folder.count + 1))
        model.edit("Set Map Image") { var copy = $0; copy.image = name; return copy }
        model.file.flush()
        model.reloadImage(store: session.store, force: true)
        model.hasFitted = false
        model.fit()
    }

    /// Notes from the sidebar become pins linked to them; an image sets the base layer.
    static func drop(_ providers: [NSItemProvider], at location: CGPoint, session: ProjectSession, model: MapModel) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return }
                    DispatchQueue.main.async { setImage(url, session: session, model: model) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string, string.hasPrefix("slate-note:") else { return }
                    let path = String(string.dropFirst("slate-note:".count))
                    DispatchQueue.main.async {
                        let note = session.links.graph.note(at: path)
                        model.addPin(at: location, title: note?.name ?? "Pin", note: note?.noteID ?? path)
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - Inspector

private struct MapInspector: View {
    let session: ProjectSession
    let model: MapModel
    let item: MapItem

    private func change(_ action: String, _ body: @escaping (inout MapItem) -> Void) {
        model.edit(action) { MapEditing.updating(item.id, in: $0, body) }
    }

    var body: some View {
        let graph = session.links.graph
        let note = item.note.flatMap { graph.resolve($0)?.path }.flatMap(graph.note(at:))
        let locations = graph.notes.filter { $0.type?.lowercased() == "location" }
        let others = graph.notes.filter { $0.type?.lowercased() != "location" }
        let scenes = session.script.book.scenes.compactMap { scene in scene.scene.sceneID.map { ($0, scene.scene.heading) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(item.kind.title, systemImage: MapModel.Tool(rawValue: item.kind.rawValue)?.symbol ?? "mappin").font(.headline)
                CommitField(title: "Title", value: item.title) { value in change("Rename") { $0.title = value } }
                Picker("Layer", selection: Binding(get: { item.layer ?? "" }, set: { layer in change("Change Layer") { $0.layer = layer } })) {
                    Text("Always shown").tag("")
                    ForEach(model.map.layers) { Text($0.name).tag($0.id) }
                }
                ColorMenu(selected: item.color) { color in change("Change Colour") { $0.color = color } }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note").font(.caption).foregroundStyle(.secondary)
                    Menu(note?.name ?? item.note ?? "None") {
                        Button("None") { change("Unlink Note") { $0.note = nil } }
                        if !locations.isEmpty {
                            Section("Locations") {
                                ForEach(locations) { candidate in
                                    Button(candidate.name) { change("Link Note") { $0.note = candidate.noteID ?? candidate.path } }
                                }
                            }
                        }
                        Section("Other Notes") {
                            ForEach(others) { candidate in
                                Button(candidate.name) { change("Link Note") { $0.note = candidate.noteID ?? candidate.path } }
                            }
                        }
                    }
                    if let note {
                        Button("Open \(note.name)") { session.open(note.path) }.buttonStyle(.link).font(.caption)
                    } else if item.note != nil {
                        Text("No note matches “\(item.note ?? "")”.").font(.caption).foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scenes").font(.caption).foregroundStyle(.secondary)
                    if scenes.isEmpty { Text("The script has no scenes yet.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(scenes, id: \.0) { id, heading in
                        HStack {
                            Toggle(isOn: Binding(get: { item.scenes.contains(id) }, set: { on in
                                change(on ? "Link Scene" : "Unlink Scene") { i in i.scenes = on ? i.scenes + [id] : i.scenes.filter { $0 != id } }
                            })) {
                                Text(heading).lineLimit(1).font(.callout)
                            }
                            .toggleStyle(.checkbox)
                            if item.scenes.contains(id) {
                                Button { session.open(sceneID: id) } label: { Image(systemName: "arrow.right.circle") }
                                    .buttonStyle(.borderless).help("Go to the scene")
                            }
                        }
                    }
                }
                if item.kind != .pin {
                    Text("\(item.points.count) corners · drag the dots on the map to reshape").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Button("Delete \(item.kind.title)", role: .destructive) { model.deleteSelection() }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }
}

// MARK: - Toolbar

struct MapToolbar: ToolbarContent {
    let session: ProjectSession
    let model: MapModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: Binding(get: { model.tool }, set: { model.tool = $0 })) {
                ForEach(MapModel.Tool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .help("Select and move, or add a pin, region or path")
        }
        ToolbarItemGroup {
            Menu {
                if model.map.layers.isEmpty {
                    Text("No layers yet")
                }
                ForEach(model.map.layers) { layer in
                    Toggle(layer.name, isOn: Binding(get: { !model.hiddenLayers.contains(layer.id) }, set: { shown in
                        if shown { model.hiddenLayers.remove(layer.id) } else { model.hiddenLayers.insert(layer.id) }
                    }))
                }
                Divider()
                Picker("New Items Go On", selection: Binding(get: { model.currentLayer ?? "" }, set: { model.currentLayer = $0.isEmpty ? nil : $0 })) {
                    Text("Always shown").tag("")
                    ForEach(model.map.layers) { Text($0.name).tag($0.id) }
                }
                Divider()
                Button("New Layer…") {
                    guard let name = ask("New Layer", "A name, such as a year the city looks different.", "") else { return }
                    let (map, id) = MapEditing.addingLayer(name, to: model.map)
                    model.file.apply(map, "Add Layer")
                    model.currentLayer = id
                }
                if !model.map.layers.isEmpty {
                    Menu("Rename Layer") {
                        ForEach(model.map.layers) { layer in
                            Button(layer.name) {
                                guard let name = ask("Rename Layer", "", layer.name) else { return }
                                model.edit("Rename Layer") { MapEditing.renamingLayer(layer.id, to: name, in: $0) }
                            }
                        }
                    }
                    Menu("Delete Layer") {
                        ForEach(model.map.layers) { layer in
                            Button(layer.name) {
                                model.edit("Delete Layer") { MapEditing.removingLayer(layer.id, from: $0) }
                                if model.currentLayer == layer.id { model.currentLayer = nil }
                            }
                        }
                    }
                }
            } label: {
                Label("Layers", systemImage: "square.3.layers.3d")
            }
            .help("Show or hide layers")
            Button { MapActions.chooseImage(session: session, model: model) } label: {
                Label(model.map.image == nil ? "Add Image" : "Change Image", systemImage: "photo")
            }
            .help("The map's base image (or drop one from Finder)")
            Button { model.zoom(by: 1 / 1.25) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
            Button { model.zoom(by: 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
            Button { model.fit() } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                .keyboardShortcut("0", modifiers: .command)
        }
    }

    @MainActor
    private func ask(_ title: String, _ message: String, _ value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
