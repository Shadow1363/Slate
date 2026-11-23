import SlateCore
import SwiftUI

/// Left column of the Script area: title page, act files and their scenes.
struct ScriptNavigator: View {
    @Bindable var workspace: ScriptWorkspace
    var session: ProjectSession?

    var body: some View {
        let book = workspace.book
        let current = workspace.currentScene
        List(selection: $workspace.selectedRow) {
            if workspace.hasTitlePage {
                Label("Title Page", systemImage: "doc.richtext").tag("title")
            }
            ForEach(book.files) { file in
                Section {
                    Label(file.name, systemImage: "doc.text")
                        .foregroundStyle(workspace.currentFile == file.path && !workspace.showingTitlePage ? .primary : .secondary)
                        .tag("file:" + file.path)
                        .dropDestination(for: String.self) { items, _ in
                            dropScenes(items, onto: file.path, at: nil)
                        }
                    ForEach(book.scenes.filter { $0.file == file.path }) { scene in
                        SceneRow(scene: scene, isCurrent: current?.id == scene.id, isExact: book.isExact)
                            .draggable("slate-scene:\(scene.file)#\(scene.scene.sceneID ?? "")")
                            .tag(ScriptWorkspace.row(for: scene))
                            .dropDestination(for: String.self) { items, _ in
                                let index = book.scenes.filter { $0.file == file.path }.firstIndex { $0.id == scene.id }
                                return dropScenes(items, onto: file.path, at: index)
                            }
                            .contextMenu {
                                Menu("Colour") {
                                    ForEach(SceneColor.allCases) { color in
                                        Button {
                                            workspace.setColor(color, for: scene)
                                        } label: {
                                            Label(color.title, systemImage: scene.scene.color == color ? "checkmark.circle.fill" : "circle.fill")
                                        }
                                        .tint(Color(sceneColor: color))
                                    }
                                    Divider()
                                    Button("None") { workspace.setColor(nil, for: scene) }
                                        .disabled(scene.scene.color == nil)
                                }
                                if book.files.count > 1 {
                                    Menu("Move to") {
                                        ForEach(book.files.filter { $0.path != scene.file }) { target in
                                            Button(target.name) { workspace.moveScene(scene, toFile: target.path) }
                                        }
                                    }
                                }
                                if let session, let id = scene.scene.sceneID {
                                    Button(scene.scene.tags.isEmpty ? "Tags…" : "Tags (\(scene.scene.tags.count))…") { session.sheet = .sceneTags(id) }
                                }
                                Divider()
                                if let session {
                                    Button("Show in Storyboard") {
                                        session.area = .storyboard
                                        session.storyboard.focusedRow = scene.scene.sceneID
                                    }
                                    .disabled(scene.scene.sceneID == nil)
                                    Button("Show on Map") { session.showOnMap(scene) }
                                        .disabled(session.mapTarget(for: scene) == nil)
                                }
                            }
                    }
                    .onMove { offsets, destination in
                        guard let from = offsets.first else { return }
                        workspace.moveScene(in: file.path, from: from, to: destination)
                    }
                }
            }
        }
        .overlay {
            if book.files.isEmpty {
                ContentUnavailableView {
                    Label("No Script Yet", systemImage: "text.page")
                } description: {
                    Text("Act files in \(workspace.film.folder)/ join in name order.")
                } actions: {
                    Button("Create script.md") { workspace.createScriptFile() }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilmBar(workspace: workspace)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        workspace.newActFile()
                    } label: {
                        Label("New Act File", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add the next act file to \(workspace.film.folder)/")
                    Button {
                        workspace.promptForNewFilm()
                    } label: {
                        Label("New Film", systemImage: "film.stack")
                    }
                    .buttonStyle(.borderless)
                    .help("Add another film to this project, for a saga or series")
                    Spacer()
                    Button {
                        workspace.showingSnapshots = true
                    } label: {
                        Label("Snapshots", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .help("Save, compare and restore snapshots (⇧⌘S saves one)")
                }
                .labelStyle(.iconOnly)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .background(.bar)
                if let status = workspace.productionStatus {
                    Label(status, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .background(.bar)
                        .help("Script › Production")
                }
                ScriptTotals(book: book)
            }
        }
        .onChange(of: workspace.selectedRow) { _, row in
            guard let row, row != workspace.lastRevealedRow else { return }
            workspace.lastRevealedRow = row
            if row == "title" {
                workspace.showTitlePage()
            } else if row.hasPrefix("file:") {
                workspace.show(file: String(row.dropFirst(5)))
            } else if let scene = book.scenes.first(where: { ScriptWorkspace.row(for: $0) == row }) {
                workspace.reveal(scene, focus: false)
            }
        }
        .navigationTitle("Script")
    }
}

extension ScriptNavigator {
    /// A scene dragged from another act file lands before `index` there (the end when nil).
    func dropScenes(_ items: [String], onto path: String, at index: Int?) -> Bool {
        var moved = false
        for item in items where item.hasPrefix("slate-scene:") {
            let payload = item.dropFirst("slate-scene:".count)
            guard let hash = payload.lastIndex(of: "#") else { continue }
            let file = String(payload[..<hash]), id = String(payload[payload.index(after: hash)...])
            guard file != path, let scene = workspace.book.scenes.first(where: { $0.file == file && $0.scene.sceneID == id }) else { continue }
            workspace.moveScene(scene, toFile: path, at: index)
            moved = true
        }
        return moved
    }
}

extension Color {
    init(sceneColor color: SceneColor) {
        self.init(red: color.rgb.red, green: color.rgb.green, blue: color.rgb.blue)
    }
}

struct SceneRow: View {
    let scene: ScriptBook.Scene
    let isCurrent: Bool
    var isExact = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(scene.scene.color.map { Color(sceneColor: $0) } ?? .clear)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(scene.label)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.scene.heading.isEmpty ? "Untitled scene" : scene.scene.heading)
                    .lineLimit(2)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Text("\(isExact ? "" : "~")\(ScriptEstimate.formatEighths(scene.eighths)) pg · \(ScriptEstimate.formatDuration(scene.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !scene.scene.tags.isEmpty {
                    Text(scene.scene.tags.map { "#" + $0 }.joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scene \(scene.label), \(scene.scene.heading)" + (scene.scene.color.map { ", \($0.title)" } ?? "")
                            + (scene.scene.tags.isEmpty ? "" : ", tagged " + scene.scene.tags.joined(separator: ", ")))
    }
}

struct ScriptTotals: View {
    let book: ScriptBook

    var body: some View {
        HStack {
            Text("\(book.scenes.count) scenes")
            Spacer()
            Text(totals)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .help(book.isExact ? "From the printed page layout." : "Estimated while you type; exact a moment after you stop.")
    }

    private var totals: String {
        let mark = book.isExact ? "" : "~"
        let pages = book.isExact ? Int(book.pageCount) : Int(book.pageCount.rounded(.up))
        return "\(mark)\(pages) pp · \(mark)\(ScriptEstimate.formatDuration(book.totalDuration))"
    }
}

/// Right side of the Script area.
struct ScriptDetail: View {
    @Bindable var workspace: ScriptWorkspace

    var body: some View {
        if workspace.showingTitlePage {
            DocumentPane(store: workspace.store, relativePath: workspace.titlePagePath, close: {})
                .id(workspace.titlePagePath)
        } else if workspace.showingPages {
            PageView(workspace: workspace)
                .toolbar { ScriptToolbar(workspace: workspace) }
                .sheet(isPresented: $workspace.showingSides) { SidesSheet(workspace: workspace) }
                .sheet(isPresented: $workspace.showingSnapshots) { SnapshotsSheet(workspace: workspace) }
        } else if let path = workspace.currentFile, let document = workspace.store.documents[path] {
            ScriptEditorPane(workspace: workspace, document: document)
                .id(path)
                .toolbar { ScriptToolbar(workspace: workspace) }
                .sheet(isPresented: $workspace.showingSides) { SidesSheet(workspace: workspace) }
                .sheet(isPresented: $workspace.showingSnapshots) { SnapshotsSheet(workspace: workspace) }
        } else if let error = workspace.openError {
            ContentUnavailableView("Can't Open Script", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            AreaPlaceholder(area: .script)
        }
    }
}

struct ScriptEditorPane: View {
    let workspace: ScriptWorkspace
    @Bindable var document: TextDocument
    @Environment(\.slateTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            DiskStateBanners(store: workspace.store, document: document, close: {})
            ScriptEditor(
                document: document,
                text: document.text,
                workspace: workspace,
                reveal: workspace.reveal,
                frameHighlight: workspace.frameHighlight,
                theme: theme,
                sources: workspace.completionSources,
                spelling: workspace.spelling,
                focusMode: workspace.focusMode,
                typewriter: workspace.typewriter
            )
            Divider()
            ScriptStatusBar(workspace: workspace, document: document)
        }
        .navigationTitle(document.name)
    }
}

struct ScriptStatusBar: View {
    let workspace: ScriptWorkspace
    let document: TextDocument

    var body: some View {
        let book = workspace.book
        HStack(spacing: 12) {
            if let caret = workspace.caret, caret.file == document.relativePath {
                Text(caret.kind.title).fontWeight(.medium)
            }
            if let scene = workspace.currentScene {
                Text("Scene \(scene.label) · \(scene.number) of \(book.scenes.count)")
                Text("\(book.isExact ? "" : "~")\(ScriptEstimate.formatEighths(scene.eighths)) pg · \(ScriptEstimate.formatDuration(scene.duration))")
            }
            Spacer()
            Text("\(book.wordCount.formatted()) words")
            Text(book.isExact ? "\(Int(book.pageCount)) pages" : "~\(Int(book.pageCount.rounded(.up))) pages")
            Text((book.isExact ? "" : "~") + ScriptEstimate.formatDuration(book.totalDuration))
            Text(document.isDirty ? "Edited" : "Saved").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// ⇧⌘O: type to filter scenes, arrows to choose, Return to jump.
struct JumpToSceneSheet: View {
    let workspace: ScriptWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var matches: [ScriptBook.Scene] {
        let scenes = workspace.book.scenes
        guard !query.isEmpty else { return scenes }
        return scenes.filter { "\($0.label) \($0.scene.heading)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let matches = matches
        VStack(spacing: 0) {
            TextField("Jump to scene", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { jump(matches) }
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(matches.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0)
                    return .handled
                }
                .onChange(of: query) { selection = 0 }
            Divider()
            ScrollViewReader { proxy in
                List(Array(matches.enumerated()), id: \.element.id) { index, scene in
                    SceneRow(scene: scene, isCurrent: false)
                        .listRowBackground(index == selection ? Color.accentColor.opacity(0.25) : Color.clear)
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = index
                            jump(matches)
                        }
                }
                .onChange(of: selection) { _, index in proxy.scrollTo(index) }
            }
            .overlay {
                if matches.isEmpty { Text("No matching scenes").foregroundStyle(.secondary) }
            }
        }
        .frame(width: 480, height: 360)
        .onAppear { fieldFocused = true }
        .background {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    private func jump(_ matches: [ScriptBook.Scene]) {
        guard matches.indices.contains(selection) else { return }
        let scene = matches[selection]
        let row = ScriptWorkspace.row(for: scene)
        workspace.lastRevealedRow = row
        workspace.selectedRow = row
        workspace.reveal(scene, focus: true)
        dismiss()
    }
}
