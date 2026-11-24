import AppKit
import SlateCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Navigator

/// Left column of the Storyboard area: scenes, boards whose scene is missing, and orphans.
struct StoryboardNavigator: View {
    let session: ProjectSession
    @FocusState private var filterFocused: Bool

    var body: some View {
        @Bindable var model = session.storyboard
        let rows = model.rows.filter(model.matchesFilter)
        let scenes = rows.filter { $0.kind == .scene }
        let missing = rows.filter { $0.kind == .missing }
        let orphans = model.orphanRows.filter(model.matchesFilter)
        List(selection: Binding(get: { model.focusedRow }, set: { model.focusedRow = $0 })) {
            Section("Scenes") {
                ForEach(scenes) { row in
                    HStack(spacing: 8) {
                        Text(row.scene?.label ?? "")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(row.title).lineLimit(1)
                        Spacer()
                        if !row.frames.isEmpty {
                            Text("\(row.frames.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(row.id)
                }
            }
            if !missing.isEmpty {
                Section("Scene Missing") {
                    ForEach(missing) { row in
                        Label(row.title, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).tag(row.id)
                    }
                }
            }
            if !orphans.isEmpty {
                Section("Orphans") {
                    ForEach(orphans) { row in
                        Label(row.title, systemImage: "tray").tag(row.id)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilmBar(workspace: session.script)
        }
        .overlay {
            if !model.sceneFilter.isEmpty && scenes.isEmpty && missing.isEmpty && orphans.isEmpty {
                ContentUnavailableView.search(text: model.sceneFilter)
            } else if scenes.isEmpty && missing.isEmpty {
                ContentUnavailableView("No Scenes Yet", systemImage: "rectangle.split.3x3",
                                       description: Text("Every scene heading in the script becomes a row here."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                let all = model.rows.filter { $0.kind == .scene }
                let framed = all.filter { !$0.frames.isEmpty }.count
                Text("\(framed) of \(all.count) scenes boarded")
                Spacer()
                Button("Tidy") { model.tidyFolders(moveMissing: false) }
                    .buttonStyle(.borderless)
                    .help("Rename board folders to match their headings")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.panel)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .searchable(text: $model.sceneFilter, placement: .sidebar, prompt: "Filter scenes")
        .searchFocused($filterFocused)
        .onChange(of: session.filterFocusRequest) { filterFocused = true }
        .navigationTitle("Storyboard")
    }
}

// MARK: - Detail

struct StoryboardDetail: View {
    let session: ProjectSession
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let model = session.storyboard
        // Not an HSplitView: its sizing widens the window past the screen when the sidebar is open.
        ItemInspectorLayout(showing: model.selected.count > 1 || model.selection.flatMap { model.frame($0) } != nil) {
            StoryboardBoard(session: session)
        } inspector: {
            if model.selected.count > 1 {
                MultiFrameInspector(model: model)
            } else if let ref = model.selection, let frame = model.frame(ref) {
                FrameInspector(session: session, ref: ref, frame: frame)
                    .id(ref)
            }
        }
        .onAppear { model.undoManager = undoManager }
        .toolbar { StoryboardToolbar(session: session) }
        .sheet(item: Binding(get: { model.sketchTarget }, set: { model.sketchTarget = $0 })) { target in
            SketchPadSheet(model: model, target: target)
        }
    }
}

/// The scene rows.
struct StoryboardBoard: View {
    /// Roughly the toolbar's height (52 pt) plus a little air.
    static let toolbarAllowance: CGFloat = 60
    /// About one row: heading and a line of frames.
    static let rowHeight: CGFloat = 200
    @State private var boardHeight: CGFloat = 800
    let session: ProjectSession
    @Environment(\.slateTheme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        let model = session.storyboard
        let rows = (model.rows + model.orphanRows).filter(model.matchesFilter)
        let atCaret = model.framesAtCaret
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        SceneBoardRow(session: session, row: row, atCaret: atCaret)
                            .id(row.id)
                        Divider()
                    }
                }
            }
            .contentMargins(.vertical, Spacing.contentVertical, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { boardHeight = $0 }
            .onChange(of: model.focusedRow, initial: true) { _, id in
                guard let id else { return }
                // scrollTo(.top) puts a row under the toolbar (it ignores that inset), so aim
                // for the point that leaves the row `toolbarAllowance` below the top.
                let anchor = UnitPoint(x: 0, y: min(0.5, Self.toolbarAllowance / max(1, boardHeight - Self.rowHeight)))
                withAnimation { proxy.scrollTo(id, anchor: anchor) }
            }
        }
        .background(Color(theme.storyboard.background))
        .overlay {
            if rows.isEmpty, !model.sceneFilter.isEmpty {
                ContentUnavailableView.search(text: model.sceneFilter)
            } else if rows.isEmpty {
                ContentUnavailableView("No Scenes Yet", systemImage: "rectangle.split.3x3",
                                       description: Text("Write scene headings in the script; each becomes a row you can fill with frames."))
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard !model.selected.isEmpty || model.selection != nil else { return .ignored }
            model.delete(model.selected.isEmpty ? [model.selection!] : Array(model.selected))
            return .handled
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll() }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .image]) { _ in
            guard let row = pasteRow else { return }
            _ = model.paste(toRow: row)
        }
        .onTapGesture { focused = true }
    }

    /// Where ⌘V goes: the selected frame's row, else the focused row.
    private var pasteRow: String? {
        let model = session.storyboard
        if let ref = model.selection, let row = (model.rows + model.orphanRows).first(where: { $0.folder?.path == ref.folder }) { return row.id }
        return model.focusedRow
    }
}

/// One scene: its header, then a strip of frames (or a placeholder).
private struct SceneBoardRow: View {
    let session: ProjectSession
    let row: StoryboardModel.Row
    let atCaret: Set<FrameRef>
    @Environment(\.slateTheme) private var theme
    @State private var targeted = false

    private var model: StoryboardModel { session.storyboard }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    let durations = model.durations(row)
                    ForEach(Array(row.frames.enumerated()), id: \.element.file) { index, frame in
                        if let folder = row.folder {
                            let ref = FrameRef(folder: folder.path, file: frame.file)
                            FrameThumb(session: session, ref: ref, frame: frame, number: index + 1,
                                       duration: durations.indices.contains(index) ? durations[index] : nil,
                                       outlined: atCaret.contains(ref))
                                .onDrop(of: [.fileURL, .utf8PlainText, .plainText], isTargeted: nil) { providers in
                                    StoryboardDrops.drop(providers, row: row.id, index: index, model: model)
                                }
                        }
                    }
                    if row.frames.isEmpty, let scene = row.scene {
                        PlaceholderCard(text: model.firstAction(of: scene) ?? scene.scene.heading)
                    }
                    if row.kind == .scene {
                        addMenu
                    }
                }
                .padding(.horizontal, Spacing.content)
                .padding(.bottom, Spacing.contentVertical)
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .trailing) {
                if row.frames.isEmpty {
                    DropHint(targeted: targeted)
                        .padding(.leading, row.kind == .scene ? FrameThumb.size.width + 80 + 2 * 10 + Spacing.content : Spacing.content)
                        .padding(.trailing, Spacing.content)
                        .padding(.bottom, Spacing.contentVertical)
                }
            }
        }
        .padding(.top, Spacing.contentVertical)
        .background(targeted ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL, .utf8PlainText, .plainText], isTargeted: $targeted) { providers in
            StoryboardDrops.drop(providers, row: row.id, index: nil, model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            switch row.kind {
            case .scene:
                if let color = row.scene?.scene.color {
                    Circle().fill(Color(sceneColor: color)).frame(width: 8, height: 8).help(color.title)
                }
                Text(row.scene?.label ?? "")
                    .font(.callout.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: .capsule)
                Text(row.title).font(.headline).lineLimit(1)
                if let scene = row.scene {
                    Text(Self.time(scene.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Estimated screen time, shared by frames without their own duration")
                }
            case .missing:
                Label("Scene missing: \(row.title)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
            case .orphan:
                Label("Orphan: \(row.title)", systemImage: "tray").font(.headline).foregroundStyle(.secondary)
            }
            Spacer()
            if row.kind == .scene, let audio = model.scratchAudio(row) {
                ScratchAudioBadge(model: model, row: row, file: audio)
            }
            Text(row.frames.count == 1 ? "1 frame" : "\(row.frames.count) frames").font(.caption).foregroundStyle(.secondary)
            if row.kind != .scene, let folder = row.folder {
                ReattachMenu(model: model, folder: folder)
                if row.kind == .missing {
                    Button("Move to Orphans") { model.moveToOrphans(folder) }
                        .help("Moves the folder to storyboard/orphans/")
                }
            } else if let id = row.sceneID {
                Button {
                    session.watch(.scene(id))
                } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .help("Watch this scene")
                Button {
                    session.area = .script
                    session.open(sceneID: id)
                } label: { Image(systemName: "text.page") }
                    .buttonStyle(.borderless)
                    .help("Go to the scene")
            }
        }
        .padding(.horizontal, Spacing.content)
    }

    private var addMenu: some View {
        Menu {
            Button("Add Images or Clips…") { StoryboardDrops.choose(row: row.id, model: model) }
            Button("New Sketch") { model.sketchTarget = .init(sceneID: row.id, file: nil) }
            Button("Paste") { _ = model.paste(toRow: row.id) }
                .disabled(!NSPasteboard.general.canReadItem(withDataConformingToTypes: [UTType.image.identifier, UTType.fileURL.identifier]))
            Divider()
            Button(model.scratchAudio(row) == nil ? "Add Scratch Audio…" : "Replace Scratch Audio…") {
                if let url = StoryboardAudio.choose(title: "Choose Scratch Audio") { model.setScratchAudio(url, row: row.id) }
            }
            if model.scratchAudio(row) != nil {
                Button("Remove Scratch Audio") { model.removeScratchAudio(row: row.id) }
            }
            Divider()
            Button("Watch Scene") { session.watch(.scene(row.id)) }
        } label: {
            Image(systemName: "plus")
                .font(.title2)
                .frame(width: 80, height: FrameThumb.size.height)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add frames: images, clips, a sketch, or paste. You can also drop files here.")
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}

private struct ReattachMenu: View {
    let model: StoryboardModel
    let folder: SceneFolder

    var body: some View {
        let free = model.rows.filter { $0.kind == .scene && $0.folder == nil }
        Menu("Reattach") {
            if free.isEmpty { Text("Every scene already has a board") }
            ForEach(free) { row in
                Button("\(row.scene?.label ?? ""). \(row.title)") { model.reattach(folder, toScene: row.id) }
            }
        }
        .fixedSize()
        .help("Give these frames to a scene that has no board yet")
    }
}

/// Fills the rest of an empty row: where to drop images or clips.
private struct DropHint: View {
    let targeted: Bool

    var body: some View {
        Label("Drop images or clips here", systemImage: "tray.and.arrow.down")
            .font(.callout)
            .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .frame(maxWidth: .infinity, minHeight: FrameThumb.size.height, maxHeight: FrameThumb.size.height)
            .background(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25),
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// An empty scene's stand-in, so the animatic plays before every scene is boarded.
private struct PlaceholderCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(10)
            .frame(width: FrameThumb.size.width, height: FrameThumb.size.height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            .help("No frames yet. This card stands in for the scene.")
    }
}

// MARK: - Frames

struct FrameThumb: View {
    let session: ProjectSession
    let ref: FrameRef
    let frame: StoryboardFrame
    let number: Int
    let duration: Double?
    let outlined: Bool
    @Environment(\.slateTheme) private var theme

    static let size = CGSize(width: 192, height: 108)

    private var model: StoryboardModel { session.storyboard }

    var body: some View {
        let selected = model.selected.contains(ref) || model.selection == ref
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.85))
                if let image = model.thumbnails.thumbnail(for: ref.path, url: model.url(ref), at: frame.isClip ? frame.inPoint : nil) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: frame.isClip ? "film" : "photo").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    Text("\(number)")
                    if let shot = frame.shot { Text(shot) }
                    if frame.isClip { Image(systemName: "film") }
                    if model.strokes(for: ref) != nil { Image(systemName: "pencil.and.scribble") }
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(5)
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration {
                    Text(String(format: "%.1fs", duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(frame.duration == nil && !frame.isClip ? .secondary : .primary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(5)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color(theme.storyboard.selectedFrame) : outlined ? Color.accentColor : Color(theme.storyboard.frameBorder),
                                  style: StrokeStyle(lineWidth: selected ? 3 : outlined ? 2 : 1, dash: outlined && !selected ? [5, 3] : []))
            }
            Text(frame.caption ?? " ")
                .font(.caption)
                .lineLimit(2)
                .frame(width: Self.size.width, alignment: .leading)
                .foregroundStyle(frame.caption == nil ? .tertiary : .primary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { model.toggleSelection(ref) } else { model.select(ref) }
        }
        .draggable(ref.payload) {
            if let image = model.thumbnails.thumbnail(for: ref.path, url: model.url(ref)) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 120)
            }
        }
        .contextMenu { FrameMenu(session: session, ref: ref) }
        .help(outlined ? "Covers the line at the script's caret" : (frame.caption ?? ref.file))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Frame \(number)\(frame.caption.map { ", " + $0 } ?? "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Double-click: edit a sketch, otherwise open the file in its own app.
    private func open() {
        if model.strokes(for: ref) != nil, let scene = model.scene(forFolder: ref.folder)?.scene.sceneID {
            model.sketchTarget = .init(sceneID: scene, file: ref.file)
        } else if let url = model.url(ref) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct FrameMenu: View {
    let session: ProjectSession
    let ref: FrameRef

    var body: some View {
        let model = session.storyboard
        if model.strokes(for: ref) != nil, let scene = model.scene(forFolder: ref.folder)?.scene.sceneID {
            Button("Edit Sketch") { model.sketchTarget = .init(sceneID: scene, file: ref.file) }
        }
        Button("Show in Script") { StoryboardActions.showInScript(ref, session: session) }
            .disabled(model.scene(forFolder: ref.folder) == nil)
        if let scene = model.scene(forFolder: ref.folder)?.scene.sceneID {
            Button("Play From Here") { session.watch(.fromFrame(scene: scene, file: ref.file)) }
        }
        Button("Show in Finder") {
            if let url = model.url(ref) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { model.delete(ref) }
    }
}

// MARK: - Actions

@MainActor
enum StoryboardActions {
    /// Goes to the frame's scene with its lines tinted.
    static func showInScript(_ ref: FrameRef, session: ProjectSession) {
        let model = session.storyboard
        model.select(ref)
        guard let scene = model.scene(forFolder: ref.folder) else { return }
        session.open(scene: scene)
    }

    /// From the script: the storyboard, on the frames that cover a line.
    static func showFrames(sceneID: String, line: Int, session: ProjectSession) {
        let model = session.storyboard
        session.area = .storyboard
        model.focusedRow = sceneID
        guard let scene = model.scenes.first(where: { $0.scene.sceneID == sceneID }), let parsed = model.parsed(for: scene) else { return }
        let covering = model.frames(covering: line, sceneID: sceneID, parsed: parsed)
        let ordered = model.row(sceneID)?.frames.compactMap { frame in covering.first { $0.file == frame.file } }
        model.select(ordered?.first)
    }
}

@MainActor
enum StoryboardDrops {
    /// Finder files are copied in; frames dragged from the board are moved.
    static func drop(_ providers: [NSItemProvider], row: String, index: Int?, model: StoryboardModel) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.add(files: [url], toRow: row, at: index) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string, let ref = FrameRef(payload: string) else { return }
                    DispatchQueue.main.async {
                        let count = model.row(row)?.frames.count ?? 0
                        model.move(ref, toRow: row, at: index ?? count)
                    }
                }
            }
        }
        return handled
    }

    static func choose(row: String, model: StoryboardModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "Images and clips are copied into the scene's board folder."
        guard panel.runModal() == .OK else { return }
        model.add(files: panel.urls, toRow: row)
    }
}

// MARK: - Inspector

private struct FrameInspector: View {
    let session: ProjectSession
    let ref: FrameRef
    let frame: StoryboardFrame
    @State private var scrubTime: Double?

    private var model: StoryboardModel { session.storyboard }

    private func change(_ action: String, _ body: @escaping (inout StoryboardFrame) -> Void) {
        model.update(ref, action, body)
    }

    var body: some View {
        let scene = model.scene(forFolder: ref.folder)
        let row = (model.rows + model.orphanRows).first { $0.folder?.path == ref.folder }
        let auto = row.flatMap { row in row.frames.firstIndex { $0.file == ref.file }.map { model.durations(row)[$0] } }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                preview
                Text(ref.file + (scene.map { " · Scene \($0.label)" } ?? "")).font(.caption).foregroundStyle(.secondary)

                Picker("Shot", selection: Binding(get: { frame.shot ?? "" }, set: { value in change("Change Shot") { $0.shot = value } })) {
                    Text("None").tag("")
                    ForEach(ShotSize.allCases) { Text("\($0.rawValue) · \($0.title)").tag($0.rawValue) }
                    if let shot = frame.shot, ShotSize(rawValue: shot) == nil { Text(shot).tag(shot) }
                }
                Picker("Move", selection: Binding(get: { frame.move ?? "" }, set: { value in change("Change Camera Move") { $0.move = value } })) {
                    Text("None").tag("")
                    ForEach(CameraMove.allCases) { Text($0.title).tag($0.rawValue) }
                    if let move = frame.move, CameraMove(rawValue: move) == nil { Text(move).tag(move) }
                }
                HStack(alignment: .bottom) {
                    CommitField(title: "Lens (mm)", value: frame.lens.map { Self.number($0) } ?? "", placeholder: "35") { text in
                        change("Change Lens") { $0.lens = Double(text.replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces)) }
                    }
                    CommitField(title: "Duration (s)", value: frame.duration.map { Self.number($0) } ?? "",
                                placeholder: auto.map { "auto \(Self.number(($0 * 10).rounded() / 10))" } ?? "auto") { text in
                        change("Change Duration") { $0.duration = Double(text.trimmingCharacters(in: .whitespaces)) }
                    }
                }
                CommitField(title: "Caption", value: frame.caption ?? "", multiline: true) { text in change("Edit Caption") { $0.caption = text } }

                if let scene, let parsed = model.parsed(for: scene) {
                    CoversPicker(frame: frame, scene: scene.scene, parsed: parsed) { range in change("Change Script Lines") { $0.scriptRange = range } }
                    Button("Show in Script") { StoryboardActions.showInScript(ref, session: session) }
                        .disabled(frame.scriptRange == nil)
                }
                if frame.isClip {
                    ClipTrim(model: model, ref: ref, frame: frame, scrubTime: $scrubTime)
                    Toggle("Play the clip's sound", isOn: Binding(get: { frame.audio }, set: { on in change("Change Audio") { $0.audio = on } }))
                }
                Divider()
                HStack {
                    if model.strokes(for: ref) != nil, let id = scene?.scene.sceneID {
                        Button("Edit Sketch") { model.sketchTarget = .init(sceneID: id, file: ref.file) }
                    }
                    Spacer()
                    Button("Move to Trash", role: .destructive) { model.delete(ref) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private var preview: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let image = model.thumbnails.thumbnail(for: ref.path, url: model.url(ref), at: frame.isClip ? (scrubTime ?? frame.inPoint) : nil) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

/// Which script lines the frame covers: a first and last element of its scene.
private struct CoversPicker: View {
    let frame: StoryboardFrame
    let scene: ScriptScene
    let parsed: ParsedScript
    let set: (String?) -> Void

    var body: some View {
        let elements = ScriptRange.elements(in: scene, of: parsed)
        let range = frame.scriptRange.flatMap(ScriptRange.init)
        let resolved = range?.lines(in: scene, of: parsed)
        VStack(alignment: .leading, spacing: 4) {
            Text("Covers").font(.caption).foregroundStyle(.secondary)
            Picker("From", selection: Binding(get: { range?.start.description ?? "" }, set: { start in
                guard let first = ScriptRange.Element(start) else { return set(nil) }
                set(ScriptRange(start: first, end: range?.end ?? first).description)
            })) {
                Text("Nothing").tag("")
                ForEach(elements, id: \.line) { item in Text(label(item)).tag(item.element.description) }
            }
            Picker("To", selection: Binding(get: { range?.end.description ?? "" }, set: { end in
                guard let start = range?.start, let last = ScriptRange.Element(end) else { return }
                set(ScriptRange(start: start, end: last).description)
            })) {
                ForEach(elements, id: \.line) { item in Text(label(item)).tag(item.element.description) }
            }
            .disabled(range == nil)
            if let text = frame.scriptRange, resolved == nil {
                Label("Lines not found (\(text)): the scene has changed.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func label(_ item: (line: Int, element: ScriptRange.Element)) -> String {
        let text = parsed.lines[item.line].text.trimmingCharacters(in: .whitespaces)
        let kind = ScriptRange.name(of: item.element.kind).capitalized
        return "\(kind) \(item.element.number): " + (text.count > 40 ? String(text.prefix(40)) + "…" : text)
    }
}

/// In and out points for a clip, with the poster following the handle being dragged.
private struct ClipTrim: View {
    let model: StoryboardModel
    let ref: FrameRef
    let frame: StoryboardFrame
    @Binding var scrubTime: Double?
    @State private var draftIn: Double?
    @State private var draftOut: Double?

    var body: some View {
        let length = model.thumbnails.clipLength(for: ref.path)
        VStack(alignment: .leading, spacing: 4) {
            Text("Trim").font(.caption).foregroundStyle(.secondary)
            if let length, length > 0 {
                let start = draftIn ?? frame.inPoint ?? 0
                let end = draftOut ?? frame.outPoint ?? length
                HStack {
                    Text("In").frame(width: 28, alignment: .leading)
                    Slider(value: Binding(get: { start }, set: { draftIn = min($0, end - 0.1); scrubTime = draftIn }), in: 0...length) { editing in
                        if !editing { commit(length) }
                    }
                    Text(String(format: "%.1f", start)).font(.caption.monospacedDigit()).frame(width: 34)
                }
                HStack {
                    Text("Out").frame(width: 28, alignment: .leading)
                    Slider(value: Binding(get: { end }, set: { draftOut = max($0, start + 0.1); scrubTime = draftOut }), in: 0...length) { editing in
                        if !editing { commit(length) }
                    }
                    Text(String(format: "%.1f", end)).font(.caption.monospacedDigit()).frame(width: 34)
                }
                Text("Clip is \(String(format: "%.1f", length)) s; plays \(String(format: "%.1f", end - start)) s. Playback comes with the animatic player.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Reading the clip…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func commit(_ length: Double) {
        let start = draftIn, end = draftOut
        draftIn = nil
        draftOut = nil
        scrubTime = nil
        model.update(ref, "Trim Clip") { frame in
            if let start { frame.inPoint = start <= 0.05 ? nil : (start * 10).rounded() / 10 }
            if let end { frame.outPoint = end >= length - 0.05 ? nil : (end * 10).rounded() / 10 }
        }
    }
}

// MARK: - Several frames

/// The inspector for several selected frames: the fields they can share.
private struct MultiFrameInspector: View {
    let model: StoryboardModel
    @Environment(\.undoManager) private var undoManager

    private var frames: [(ref: FrameRef, frame: StoryboardFrame)] {
        model.selected.sorted { ($0.folder, $0.file) < ($1.folder, $1.file) }.compactMap { ref in model.frame(ref).map { (ref, $0) } }
    }

    static let mixed = "\u{0}mixed"

    /// The frames' common text value ("" when none), or `mixed` when they differ.
    private func shared(_ value: (StoryboardFrame) -> String?) -> String {
        let values = Set(frames.map { value($0.frame) ?? "" })
        return values.count == 1 ? values.first! : Self.mixed
    }

    private func change(_ action: String, _ body: @escaping (inout StoryboardFrame) -> Void) {
        undoManager?.beginUndoGrouping()
        for item in frames { model.update(item.ref, action, body) }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(action)
    }

    var body: some View {
        Form {
            Section("\(frames.count) Frames") {
                picker("Shot", value: shared(\.shot), options: ShotSize.allCases.map { ($0.rawValue, "\($0.rawValue) · \($0.title)") }) { value in
                    change("Change Shot") { $0.shot = value }
                }
                picker("Move", value: shared(\.move), options: CameraMove.allCases.map { ($0.rawValue, $0.title) }) { value in
                    change("Change Camera Move") { $0.move = value }
                }
                let duration = shared { $0.duration.map { FrameInspector.number($0) } }
                CommitField(title: "Duration (s)", value: duration == Self.mixed ? "" : duration,
                            placeholder: duration == Self.mixed ? "mixed" : "auto") { text in
                    change("Change Duration") { $0.duration = Double(text.trimmingCharacters(in: .whitespaces)) }
                }
            }
            Section {
                Button("Move \(frames.count) Frames to Trash", role: .destructive) { model.delete(frames.map(\.ref)) }
            }
        }
        .formStyle(.grouped)
    }

    /// A picker that shows "Mixed" until a value is chosen for all.
    private func picker(_ title: String, value: String, options: [(tag: String, label: String)], set: @escaping (String?) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: { chosen in
            if chosen != Self.mixed { set(chosen.isEmpty ? nil : chosen) }
        })) {
            if value == Self.mixed { Text("Mixed").tag(Self.mixed) }
            Text("None").tag("")
            ForEach(options, id: \.tag) { Text($0.label).tag($0.tag) }
        }
    }
}
