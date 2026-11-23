import AppKit
import SlateCore
import SwiftUI

/// A `*.timeline.json` file in the Universe area.
struct TimelinePane: View {
    let session: ProjectSession
    let document: TextDocument
    @State private var model: TimelineModel
    @State private var showingWarnings = false
    @Environment(\.undoManager) private var undoManager

    init(session: ProjectSession, document: TextDocument) {
        self.session = session
        self.document = document
        _model = State(initialValue: TimelineModel(document: document))
    }

    var body: some View {
        let context = TimelineContext(session: session, model: model)
        VStack(spacing: 0) {
            DiskStateBanners(store: session.store, document: document, close: { session.universeSelection = nil })
            if let error = model.file.parseError {
                Banner(systemImage: "exclamationmark.triangle.fill", message: "This timeline can't be read: \(error) Fix the file and it reloads.") {}
                DocumentEditor(store: session.store, document: document, close: { session.universeSelection = nil })
            } else {
                if let pending = model.pendingJump {
                    Banner(systemImage: "arrow.uturn.left.circle", message: "Click the event where “\(model.timeline.event(pending)?.title ?? "")” arrives.") {
                        Button("Cancel") { model.pendingJump = nil }
                    }
                }
                HSplitView {
                    TimelineGrid(context: context)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    if model.selectedEvent != nil || model.selectedLane != nil || model.selectedBranch != nil {
                        TimelineInspector(context: context)
                            .frame(minWidth: 250, idealWidth: 290, maxWidth: 380, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle(Self.title(document.relativePath))
        .toolbar { TimelineToolbar(context: context, showingWarnings: $showingWarnings) }
        .onAppear { model.file.undoManager = undoManager }
        .onChange(of: document.text) { model.file.documentChanged() }
        .onDisappear { model.file.flush() }
    }

    /// `universe/timelines/main.timeline.json` → `main`.
    static func title(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(TimelineFile.suffix) ? String(name.dropLast(TimelineFile.suffix.count)) : name
    }
}

/// What every timeline view needs, worked out once per render.
@MainActor
struct TimelineContext {
    let session: ProjectSession
    let model: TimelineModel
    let analysis: TimelineAnalysis
    let scenes: [(id: String, heading: String)]
    let warnings: [TimelineWarning]

    init(session: ProjectSession, model: TimelineModel) {
        self.session = session
        self.model = model
        let book = session.script.book
        var order: [String: Int] = [:]
        var scenes: [(id: String, heading: String)] = []
        for scene in book.scenes {
            guard let id = scene.scene.sceneID, order[id] == nil else { continue }
            order[id] = scene.number
            scenes.append((id, scene.scene.heading))
        }
        self.scenes = scenes
        analysis = TimelineAnalysis(file: model.timeline, sceneOrder: order)
        let graph = session.links.graph
        warnings = analysis.warnings { a, b in
            (graph.resolve(a)?.path ?? LinkGraph.key(a)) == (graph.resolve(b)?.path ?? LinkGraph.key(b))
        }
    }

    var timeline: TimelineFile { model.timeline }

    var layout: TimelineLayout {
        TimelineLayout.make(analysis, mode: model.mode, scenes: scenes, traveller: model.traveller ?? timeline.lanes.first?.id)
    }

    func warnings(for event: String) -> [TimelineWarning] {
        warnings.filter { $0.events.contains(event) }
    }
}

// MARK: - Colours

@MainActor
enum TimelineColors {
    static func lane(_ id: String?, in file: TimelineFile, theme: ResolvedTheme) -> Color {
        guard let id, let index = file.lanes.firstIndex(where: { $0.id == id }) else { return .secondary }
        if let custom = CanvasColor.color(file.lanes[index].color) { return custom }
        let palette = theme.canvas.laneColors
        return palette.isEmpty ? .accentColor : Color(palette[index % palette.count])
    }

    static func branch(_ id: String, in file: TimelineFile, theme: ResolvedTheme) -> Color {
        let index = file.branches.firstIndex { $0.id == id } ?? 0
        if file.branches.indices.contains(index), let custom = CanvasColor.color(file.branches[index].color) { return custom }
        let palette = theme.canvas.branchColors
        return palette.isEmpty ? .secondary : Color(palette[index % palette.count])
    }
}

// MARK: - The grid

struct TimelineGrid: View {
    let context: TimelineContext
    @Environment(\.slateTheme) private var theme
    @FocusState private var focused: Bool

    nonisolated static let labelWidth = 150.0
    nonisolated static let headerHeight = 46.0
    nonisolated static let slotHeight = 46.0
    nonisolated static let rowPadding = 8.0

    private var model: TimelineModel { context.model }

    var body: some View {
        let layout = context.layout
        let geometry = Geometry(layout: layout, columnWidth: model.columnWidth)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                rowBackgrounds(layout, geometry)
                columnHeaders(layout, geometry)
                TimelineConnections(context: context, layout: layout, geometry: geometry)
                    .allowsHitTesting(false)
                ForEach(layout.items) { item in
                    if let event = context.timeline.event(item.event) {
                        let rect = geometry.rect(item)
                        EventChip(context: context, event: event, item: item)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                rowLabels(layout, geometry)
            }
            .frame(width: geometry.width, height: geometry.height, alignment: .topLeading)
        }
        .background(Color(theme.editor.background))
        .overlay {
            if layout.items.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "timeline.selection")
                } description: {
                    Text(emptyMessage)
                } actions: {
                    if model.mode == .world {
                        Button("Add Event") { model.addEvent(lane: nil) }
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            model.deleteSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            if model.pendingJump != nil { model.pendingJump = nil } else { model.select(event: nil) }
            return .handled
        }
        .onTapGesture { focused = true }
    }

    private var emptyTitle: String {
        switch model.mode {
        case .world: "No Events Yet"
        case .story: "No Events in Scenes"
        case .personal: "Nothing Lived Yet"
        }
    }

    private var emptyMessage: String {
        switch model.mode {
        case .world: "Add a lane for each character or thread, then add events. Double-click a row to add an event there."
        case .story: "Link events to scenes in the inspector, and they appear here in the order the film shows them."
        case .personal: "Events on this lane, and the jumps this character makes, appear here in the order they live them."
        }
    }

    /// Where things sit, in points.
    struct Geometry {
        let layout: TimelineLayout
        let columnWidth: Double
        let rowTops: [Double]
        let rowHeights: [Double]

        init(layout: TimelineLayout, columnWidth: Double) {
            self.layout = layout
            self.columnWidth = columnWidth
            var tops: [Double] = []
            var heights: [Double] = []
            var y = TimelineGrid.headerHeight
            for slots in layout.slots {
                tops.append(y)
                let height = Double(slots) * TimelineGrid.slotHeight + TimelineGrid.rowPadding * 2
                heights.append(height)
                y += height
            }
            rowTops = tops
            rowHeights = heights
        }

        var width: Double { TimelineGrid.labelWidth + Double(max(layout.columns.count, 1)) * columnWidth + 40 }
        var height: Double { (rowTops.last.map { $0 + rowHeights.last! } ?? TimelineGrid.headerHeight) + 40 }

        func columnX(_ column: Int) -> Double { TimelineGrid.labelWidth + Double(column) * columnWidth }

        func rect(_ item: TimelineLayout.Item) -> CGRect {
            let x = columnX(item.column) + 6
            let width = Double(item.endColumn - item.column + 1) * columnWidth - 12
            let y = rowTops[item.row] + TimelineGrid.rowPadding + Double(item.slot) * TimelineGrid.slotHeight + 3
            return CGRect(x: x, y: y, width: width, height: TimelineGrid.slotHeight - 6)
        }

        func column(at x: Double) -> Int? {
            let column = Int(((x - TimelineGrid.labelWidth) / columnWidth).rounded(.down))
            return layout.columns.indices.contains(column) ? column : nil
        }
    }

    private func rowBackgrounds(_ layout: TimelineLayout, _ geometry: Geometry) -> some View {
        ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, row in
            let selected = (row.isMainBranch && row.lane != nil && row.lane == model.selectedLane) || (!row.isMainBranch && row.branch == model.selectedBranch)
            Rectangle()
                .fill(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : Color.clear)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                .overlay { if selected { Rectangle().fill(Color.accentColor.opacity(0.06)) } }
                .frame(width: geometry.width, height: geometry.rowHeights[index])
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    guard model.mode == .world else { return }
                    let world = geometry.column(at: value.location.x).flatMap { layout.columns[$0].world }
                    model.addEvent(lane: row.lane, branch: row.branch, world: world)
                })
                .onTapGesture { model.select(event: nil); focused = true }
                .offset(y: geometry.rowTops[index])
        }
    }

    private func columnHeaders(_ layout: TimelineLayout, _ geometry: Geometry) -> some View {
        ForEach(Array(layout.columns.enumerated()), id: \.element.id) { index, column in
            VStack(alignment: .leading, spacing: 1) {
                Text(column.label).font(.caption.weight(.semibold)).lineLimit(1)
                if let detail = column.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(width: geometry.columnWidth, height: TimelineGrid.headerHeight, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1) }
            .help(column.detail.map { column.label + " · " + $0 } ?? column.label)
            .onTapGesture(count: 2) {
                if column.id.hasPrefix("s:") { context.session.open(sceneID: String(column.id.dropFirst(2))) }
            }
            .offset(x: geometry.columnX(index))
        }
    }

    private func rowLabels(_ layout: TimelineLayout, _ geometry: Geometry) -> some View {
        ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, row in
            HStack(spacing: 6) {
                if row.isMainBranch {
                    Circle().fill(TimelineColors.lane(row.lane, in: context.timeline, theme: theme)).frame(width: 9, height: 9)
                } else {
                    Image(systemName: "arrow.triangle.branch").font(.caption)
                        .foregroundStyle(TimelineColors.branch(row.branch, in: context.timeline, theme: theme))
                }
                Text(row.title).font(row.isMainBranch ? .callout.weight(.medium) : .caption).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: TimelineGrid.labelWidth, height: geometry.rowHeights[index], alignment: .leading)
            .background(.bar)
            .overlay(alignment: .trailing) { Divider() }
            .contentShape(Rectangle())
            .onTapGesture {
                if !row.isMainBranch {
                    model.select(branch: row.branch)
                } else if let lane = row.lane {
                    model.select(lane: lane)
                }
            }
            .contextMenu {
                if model.mode == .world {
                    Button("Add Event Here") { model.addEvent(lane: row.lane, branch: row.branch) }
                }
                if let lane = row.lane, row.isMainBranch {
                    Button("Follow \(context.timeline.lane(lane)?.name ?? lane)'s Life") {
                        model.traveller = lane
                        model.mode = .personal
                    }
                    Divider()
                    Button("Move Up") { model.edit("Move Lane") { TimelineEditing.movingLane(lane, by: -1, in: $0) } }
                    Button("Move Down") { model.edit("Move Lane") { TimelineEditing.movingLane(lane, by: 1, in: $0) } }
                    Divider()
                    Button("Delete Lane", role: .destructive) {
                        model.edit("Delete Lane") { TimelineEditing.removingLane(lane, from: $0) }
                    }
                }
                if !row.isMainBranch {
                    Button("Delete Branch", role: .destructive) {
                        model.edit("Delete Branch") { TimelineEditing.removingBranch(row.branch, from: $0) }
                    }
                }
            }
            .offset(y: geometry.rowTops[index])
        }
    }
}

// MARK: - Events

private struct EventChip: View {
    let context: TimelineContext
    let event: TimelineEvent
    let item: TimelineLayout.Item
    @Environment(\.slateTheme) private var theme

    private var model: TimelineModel { context.model }

    var body: some View {
        let color = CanvasColor.color(event.color) ?? TimelineColors.lane(event.lane, in: context.timeline, theme: theme)
        let selected = model.selectedEvent == event.id
        let warned = !context.warnings(for: event.id).isEmpty
        let isJumpEnd = context.timeline.jumps.contains { $0.from == event.id || $0.to == event.id }
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isJumpEnd {
                Image(systemName: "arrow.uturn.left").font(.caption2).foregroundStyle(Color(theme.canvas.jumpArc))
            }
            if warned {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : color.opacity(0.7), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture(count: 2) { openScene() }
        .onTapGesture {
            if model.pendingJump != nil { model.completeJump(to: event.id) } else { model.select(event: event.id) }
        }
        .help(help)
        .contextMenu { EventMenu(context: context, event: event) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(event.title), \(context.timeline.scale.label(event.world))")
    }

    private var subtitle: String {
        let scale = context.timeline.scale
        if model.mode == .world {
            return event.scenes.isEmpty ? (event.location ?? "") : "Scene " + event.scenes.joined(separator: ", ")
        }
        return scale.label(event.world) + (event.end.map { " – " + scale.label($0) } ?? "")
    }

    private var help: String {
        var lines = [event.title, context.timeline.scale.label(event.world)]
        if let summary = event.summary { lines.append(summary) }
        lines += context.warnings(for: event.id).map { "⚠︎ " + $0.message }
        return lines.joined(separator: "\n")
    }

    private func openScene() {
        if let scene = event.scenes.first(where: { id in context.scenes.contains { $0.id == id } }) {
            context.session.open(sceneID: scene)
        } else {
            model.select(event: event.id)
        }
    }
}

private struct EventMenu: View {
    let context: TimelineContext
    let event: TimelineEvent

    var body: some View {
        let model = context.model
        ForEach(event.scenes, id: \.self) { scene in
            Button("Open Scene \(scene)") { context.session.open(sceneID: scene) }
                .disabled(!context.scenes.contains { $0.id == scene })
        }
        if let location = event.location, let path = context.session.links.graph.resolve(location)?.path {
            Button("Open \(context.session.links.graph.note(at: path)?.name ?? location)") { context.session.open(path) }
        }
        Divider()
        Button("Jump From Here…") { model.pendingJump = event.id }
        Button("Branch From Here") { model.branch(from: event.id) }
        Button("Duplicate") {
            var copy = event
            copy.object["id"] = .string(TimelineEditing.newEventID(in: context.timeline))
            copy.title = event.title + " (copy)"
            model.edit("Duplicate Event") { TimelineEditing.adding(copy, to: $0) }
            model.select(event: copy.id)
        }
        Divider()
        Button("Delete Event", role: .destructive) {
            model.edit("Delete Event") { TimelineEditing.removingEvents([event.id], from: $0) }
            if model.selectedEvent == event.id { model.selectedEvent = nil }
        }
    }
}

// MARK: - Jumps, forks and rejoins

private struct TimelineConnections: View {
    let context: TimelineContext
    let layout: TimelineLayout
    let geometry: TimelineGrid.Geometry
    @Environment(\.slateTheme) private var theme

    var body: some View {
        Canvas { canvas, _ in
            let file = context.timeline
            let jumpColor = Color(theme.canvas.jumpArc)
            for jump in file.jumps {
                guard let from = item(jump.from), let to = item(jump.to) else { continue }
                let a = geometry.rect(from), b = geometry.rect(to)
                let start = CGPoint(x: a.midX, y: a.minY), end = CGPoint(x: b.midX, y: b.minY)
                let lift = 36 + abs(end.x - start.x) * 0.12
                let control = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - lift)
                var path = Path()
                path.move(to: start)
                path.addQuadCurve(to: end, control: control)
                canvas.stroke(path, with: .color(jumpColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                canvas.fill(arrowHead(at: end, from: control), with: .color(jumpColor))
            }
            // Forks and rejoins: dashed lines from the main line to the branch's first and last events.
            for branch in file.branches where branch.id != file.mainBranch {
                let rows = Set(layout.rows.indices.filter { layout.rows[$0].branch == branch.id })
                let items = layout.items.filter { rows.contains($0.row) }.sorted { $0.column < $1.column }
                guard let first = items.first, let last = items.last else { continue }
                let color = TimelineColors.branch(branch.id, in: file, theme: theme)
                let style = StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                if let fork = branch.forksFrom.flatMap(item) {
                    let a = geometry.rect(fork), b = geometry.rect(first)
                    canvas.stroke(elbow(from: CGPoint(x: a.midX, y: a.maxY), to: CGPoint(x: b.minX, y: b.midY)), with: .color(color), style: style)
                }
                if let rejoin = branch.rejoins.flatMap(item) {
                    let a = geometry.rect(last), b = geometry.rect(rejoin)
                    canvas.stroke(elbow(from: CGPoint(x: a.maxX, y: a.midY), to: CGPoint(x: b.midX, y: b.maxY)), with: .color(color), style: style)
                }
            }
        }
        .accessibilityChildren {
            let events = context.model.timeline.events
            ForEach(Array(context.model.timeline.jumps.enumerated()), id: \.offset) { _, jump in
                let from = events.first { $0.id == jump.from }?.title ?? jump.from
                let to = events.first { $0.id == jump.to }?.title ?? jump.to
                Rectangle().accessibilityLabel("Jump from \(from) to \(to)")
            }
        }
        .frame(width: geometry.width, height: geometry.height)
    }

    private func item(_ event: String) -> TimelineLayout.Item? {
        layout.item(for: event)
    }

    private func elbow(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x, y: (a.y + b.y) / 2), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
        return path
    }

    private func arrowHead(at tip: CGPoint, from control: CGPoint) -> Path {
        let angle = atan2(tip.y - control.y, tip.x - control.x)
        let size = 8.0
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - size * cos(angle - 0.45), y: tip.y - size * sin(angle - 0.45)))
        path.addLine(to: CGPoint(x: tip.x - size * cos(angle + 0.45), y: tip.y - size * sin(angle + 0.45)))
        path.closeSubpath()
        return path
    }
}

// MARK: - Toolbar

struct TimelineToolbar: ToolbarContent {
    let context: TimelineContext
    @Binding var showingWarnings: Bool

    var body: some ToolbarContent {
        let model = context.model
        ToolbarItem(placement: .principal) {
            Picker("View", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                ForEach(TimelineViewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("World order: when things happen. Story order: as the film shows them. Personal: one character's life, following their jumps.")
        }
        if model.mode == .personal, !context.timeline.lanes.isEmpty {
            ToolbarItem {
                Picker("Character", selection: Binding(get: { model.traveller ?? context.timeline.lanes.first?.id ?? "" },
                                                       set: { model.traveller = $0 })) {
                    ForEach(context.timeline.lanes) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
            }
        }
        ToolbarItemGroup {
            Menu {
                Button("Add Event") { model.addEvent(lane: model.selectedLane) }
                Button("Add Lane") { model.addLane() }
                let characters = context.session.links.graph.notes.filter { $0.type?.lowercased() == "character" }
                if !characters.isEmpty {
                    Menu("Add Lane for Character") {
                        ForEach(characters) { note in
                            Button(note.name) { model.addLane(name: note.aliases.first ?? note.name, note: note.noteID ?? note.path) }
                        }
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add an event or a lane")
            Menu {
                Picker("Time Units", selection: Binding(get: { context.timeline.units }, set: { units in
                    model.edit("Change Time Units") { var copy = $0; copy.units = units; return copy }
                })) {
                    ForEach(TimeUnits.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                if context.timeline.units == .custom {
                    Divider()
                    Text("Eras: " + (context.timeline.eras.isEmpty ? "none" : context.timeline.eras.joined(separator: ", ")))
                    Button("Edit Eras…") { editEras(model) }
                }
            } label: {
                Label("Time Units", systemImage: "calendar")
            }
            .help("Dates, relative days, or a custom calendar")
            Button { model.zoom(by: 1 / 1.25) } label: { Label("Narrower", systemImage: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
            Button { model.zoom(by: 1.25) } label: { Label("Wider", systemImage: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
            Button { showingWarnings.toggle() } label: {
                Label(context.warnings.isEmpty ? "No Warnings" : "\(context.warnings.count) Warnings",
                      systemImage: context.warnings.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
            }
            .labelStyle(.titleAndIcon)
            .help("Continuity checks")
            .popover(isPresented: $showingWarnings, arrowEdge: .bottom) {
                WarningsList(context: context)
            }
        }
    }

    @MainActor
    private func editEras(_ model: TimelineModel) {
        let alert = NSAlert()
        alert.messageText = "Eras"
        alert.informativeText = "Era names, oldest first, separated by commas. Times are written “<era> <year>”."
        let field = NSTextField(string: context.timeline.eras.joined(separator: ", "))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let eras = field.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.edit("Change Eras") { var copy = $0; copy.eras = eras; return copy }
    }
}

private struct WarningsList: View {
    let context: TimelineContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Continuity").font(.headline).padding(12)
            Divider()
            if context.warnings.isEmpty {
                Text("No problems found.").foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(context.warnings) { warning in
                            Button {
                                if let first = warning.events.first { context.model.select(event: first) }
                            } label: {
                                Label(warning.message, systemImage: symbol(warning.kind))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 380)
    }

    private func symbol(_ kind: TimelineWarning.Kind) -> String {
        switch kind {
        case .time: "clock.badge.questionmark"
        case .reference: "link.badge.plus"
        case .twoPlaces: "person.2.wave.2"
        case .cause: "arrow.triangle.2.circlepath"
        case .unplaced: "arrow.uturn.left"
        }
    }
}
