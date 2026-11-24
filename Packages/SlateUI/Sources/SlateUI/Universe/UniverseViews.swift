import AppKit
import SlateCore
import SwiftUI

/// Left column of the Universe area: the rough draft and its outline, then
/// notes grouped by type, then other files (canvases, timelines, maps).
struct UniverseNavigator: View {
    @Bindable var session: ProjectSession
    @AppStorage("universe.tagsExpanded") private var tagsExpanded = true

    var body: some View {
        let graph = session.links.graph
        let groups = groups(graph)
        List(selection: $session.universeSelection) {
            // The rough draft is optional: delete it and the section goes; + › New Rough Draft brings it back.
            if session.exists(ProjectLayout.draft) {
                Section("Rough Draft") {
                    let tree = HeadingTree.build(draftHeadings(graph))
                    HStack(spacing: 4) {
                        if tree.isEmpty {
                            Color.clear.frame(width: 14, height: 14)
                        } else {
                            OutlineChevron(isOpen: session.outline.isOpen(ProjectLayout.draft)) { branch in
                                withAnimation(.snappy(duration: 0.15)) {
                                    session.outline.toggle(ProjectLayout.draft, tree: tree, branch: branch)
                                }
                            }
                        }
                        Label("Draft", systemImage: "doc.richtext")
                    }
                    .tag(ProjectLayout.draft)
                    .contextMenu { fileMenu(ProjectLayout.draft) }
                    if session.outline.isOpen(ProjectLayout.draft) {
                        ForEach(HeadingTree.rows(tree, isOpen: { session.outline.isOpen(ProjectLayout.draft, heading: $0) })) { row in
                            HeadingRow(session: session, path: ProjectLayout.draft, row: row, tree: tree)
                        }
                    }
                }
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.notes) { note in
                        // A note's headings are listed beside it, under its infobox (NoteIndex).
                        NoteRow(note: note, backlinks: graph.backlinks(to: note.path).count)
                            .draggable("slate-note:" + note.path)
                            .tag(note.path)
                            .contextMenu { noteMenu(note) }
                    }
                }
            }
            let tags = session.tagIndex.tags
            if !tags.isEmpty {
                Section(isExpanded: $tagsExpanded) {
                    ForEach(tags, id: \.tag) { tag in
                        Button {
                            session.showSearch("!t \(tag.tag) ")
                        } label: {
                            HStack {
                                Label("#" + tag.tag, systemImage: "number")
                                Spacer()
                                Text("\(tag.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Show everything tagged #\(tag.tag)")
                        .contextMenu {
                            Button("Show All") { session.showSearch("!t \(tag.tag) ") }
                            Button("Rename…") { session.promptRenameTag(tag.tag) }
                            Divider()
                            Button("Remove from All…", role: .destructive) { session.confirmRemoveTag(tag.tag) }
                        }
                    }
                } header: {
                    Text("Tags")
                }
            }
            let canvases = canvasFiles
            Section("Canvases") {
                ForEach(canvases, id: \.self) { path in
                    Label(((path as NSString).lastPathComponent as NSString).deletingPathExtension, systemImage: "rectangle.3.group")
                        .tag(path)
                        .contextMenu { fileMenu(path) }
                }
                Button {
                    session.createCanvas()
                } label: {
                    Label("New Canvas", systemImage: "plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section("Timelines") {
                ForEach(session.timelineFiles, id: \.self) { path in
                    Label(TimelinePane.title(path), systemImage: "timeline.selection")
                        .tag(path)
                        .contextMenu { fileMenu(path) }
                }
                Button {
                    session.createTimeline()
                } label: {
                    Label("New Timeline", systemImage: "plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section("Maps") {
                ForEach(session.mapFiles, id: \.self) { path in
                    Label(MapPane.title(path), systemImage: "map")
                        .tag(path)
                        .contextMenu { fileMenu(path) }
                }
                Button {
                    session.createMap()
                } label: {
                    Label("New Map", systemImage: "plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            let others = otherFiles(graph)
            if !others.isEmpty {
                Section("Other Files") {
                    ForEach(others, id: \.self) { path in
                        Label((path as NSString).lastPathComponent, systemImage: ProjectLayout.isTextFile(path) ? "doc.text" : "doc")
                            .help(path)
                            .tag(path)
                            .contextMenu { fileMenu(path) }
                    }
                }
            }
        }
        .overlay {
            if graph.notes.isEmpty && !session.exists(ProjectLayout.draft) && canvasFiles.isEmpty && session.timelineFiles.isEmpty && session.mapFiles.isEmpty {
                ContentUnavailableView("No Notes Yet", systemImage: "globe.americas", description: Text("Add characters, locations and rules with +."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(graph.notes.count) notes")
                Spacer()
                let unresolved = graph.unresolved.count
                if unresolved > 0 {
                    Text("\(unresolved) unresolved links").help("Links that don't match any note's name, alias or file name.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(session.templates) { template in
                        Button {
                            session.sheet = .newNote(type: template.type, name: "")
                        } label: {
                            Label(template.label, systemImage: template.icon ?? icon(for: template.type))
                        }
                    }
                    Button("Import Voice Note…") { session.importVoiceNotes() }
                    Divider()
                    Button("New Canvas") { session.createCanvas() }
                    Button("New Timeline") { session.createTimeline() }
                    Button("New Map") { session.createMap() }
                    if !session.exists(ProjectLayout.draft) {
                        Button("New Rough Draft") { session.createDraft() }
                    }
                    Button("Edit Templates…") { session.sheet = .templates(nil) }
                } label: {
                    Label("New Note", systemImage: "plus")
                }
                .help("New note from a template (⌘N)")
            }
        }
        .navigationTitle("Universe")
    }

    private struct Group {
        let title: String
        let notes: [Note]
    }

    /// Notes by folder, in template order, then any other folders.
    private func groups(_ graph: LinkGraph) -> [Group] {
        var byFolder: [String: [Note]] = [:]
        for note in graph.notes where note.path.hasPrefix(ProjectLayout.universe + "/") {
            let parts = note.path.split(separator: "/")
            let folder = parts.count > 2 ? String(parts[1]) : ""
            byFolder[folder, default: []].append(note)
        }
        var result: [Group] = []
        for template in session.templates {
            if let notes = byFolder.removeValue(forKey: template.folder) {
                result.append(Group(title: plural(template.label, folder: template.folder), notes: notes))
            }
        }
        for folder in byFolder.keys.sorted() {
            result.append(Group(title: folder.isEmpty ? "Notes" : folder.replacingOccurrences(of: "-", with: " ").capitalized, notes: byFolder[folder] ?? []))
        }
        return result
    }

    private func plural(_ label: String, folder: String) -> String {
        label == "Freeform Note" ? "Notes" : folder.capitalized
    }

    private func draftHeadings(_ graph: LinkGraph) -> [MarkdownOutline.Heading] {
        guard let document = session.store.documents[ProjectLayout.draft] else {
            let text = (try? session.store.readText(at: ProjectLayout.draft)) ?? ""
            return MarkdownOutline(parsing: text).headings
        }
        return MarkdownOutline(parsing: document.text).headings
    }

    private func otherFiles(_ graph: LinkGraph) -> [String] {
        let shown = Set(session.timelineFiles + session.mapFiles).union(session.mapImages)
        return (session.store.files[.universe] ?? []).map(\.relativePath)
            .filter { $0 != ProjectLayout.draft && graph.note(at: $0) == nil && !$0.hasSuffix(".canvas") && !$0.hasPrefix("universe/canvases/images/") }
            .filter { !shown.contains($0) }
    }

    private var canvasFiles: [String] {
        (session.store.files[.universe] ?? []).map(\.relativePath).filter { $0.hasSuffix(".canvas") }
    }

    @ViewBuilder
    private func noteMenu(_ note: Note) -> some View {
        Button("Rename…") { session.sheet = .rename(note.path, nil) }
        fileMenu(note.path)
    }

    @ViewBuilder
    private func fileMenu(_ path: String) -> some View {
        Button("Show in Finder") {
            if let url = try? session.store.url(for: path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { session.trash(path) }
    }
}

struct NoteRow: View {
    let note: Note
    let backlinks: Int

    var body: some View {
        HStack {
            Label(note.name, systemImage: icon(for: note.type))
                .lineLimit(1)
            Spacer()
            if note.frontmatterError != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("The frontmatter isn't valid YAML.")
            }
            if backlinks > 0 {
                Text("\(backlinks)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).help("\(backlinks) backlinks")
            }
        }
    }
}

/// Right side of the Universe area.
struct UniverseDetail: View {
    @Bindable var session: ProjectSession

    var body: some View {
        if let path = session.universeSelection {
            UniverseFilePane(session: session, path: path)
                .id(path)
        } else {
            ContentUnavailableView {
                Label("Universe", systemImage: "globe.americas")
            } description: {
                Text("Choose a note, canvas, timeline or map, or make a note with + (⌘N).")
            }
        }
    }
}

/// Opens one file from the Universe folder in the right editor.
struct UniverseFilePane: View {
    let session: ProjectSession
    let path: String
    @State private var document: TextDocument?
    @State private var error: String?

    private var isMarkdown: Bool { ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) }

    var body: some View {
        Group {
            if let document {
                if path.hasSuffix(".canvas") {
                    CanvasPane(session: session, document: document)
                } else if path.lowercased().hasSuffix(TimelineFile.suffix) {
                    TimelinePane(session: session, document: document)
                } else if path.lowercased().hasSuffix(MapFile.suffix) {
                    MapPane(session: session, document: document)
                } else if path == ProjectLayout.draft || !isMarkdown {
                    if isMarkdown {
                        MarkdownPane(session: session, document: document)
                    } else {
                        DocumentEditor(store: session.store, document: document, close: { session.universeSelection = nil },
                                       reveal: session.noteReveal)
                    }
                } else {
                    NoteEditor(session: session, document: document)
                }
            } else if let error {
                ContentUnavailableView("Can't Open File", systemImage: "doc.badge.ellipsis", description: Text(error))
            } else if !ProjectLayout.isTextFile(path) {
                ContentUnavailableView("Not a Text File", systemImage: "doc", description: Text("Images open in Finder or Preview; maps show theirs on the map."))
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            guard ProjectLayout.isTextFile(path) else { return }
            do {
                document = try session.store.document(at: path)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A plain Markdown file (the rough draft) in the styled editor.
struct MarkdownPane: View {
    let session: ProjectSession
    @Bindable var document: TextDocument
    @Environment(\.slateTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            DiskStateBanners(store: session.store, document: document, close: { session.universeSelection = nil })
            MarkdownEditor(document: document, text: document.text, hidesFrontmatter: false, theme: theme,
                           reveal: session.noteReveal, linkVersion: session.links.version, session: session,
                           spelling: session.noteSpelling)
            Divider()
            FileStatusBar(document: document)
        }
        .navigationTitle(document.name)
    }
}

struct FileStatusBar: View {
    let document: TextDocument

    var body: some View {
        HStack(spacing: 12) {
            Text(document.relativePath)
            Spacer()
            Text("\(wordCount.formatted()) words")
            Text(document.isDirty ? "Edited" : "Saved").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var wordCount: Int {
        Frontmatter.split(document.text).body.split { $0.isWhitespace || $0.isNewline }.count
    }
}
