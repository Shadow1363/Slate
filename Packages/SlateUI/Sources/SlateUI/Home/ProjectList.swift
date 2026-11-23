import SlateCore
import SwiftUI

/// The library as a list: title, last edited, pages, runtime and to-dos.
struct ProjectList: View {
    let entries: [LibraryEntry]
    let open: (LibraryEntry) -> Void
    @State private var selection: LibraryEntry.ID?

    var body: some View {
        Table(entries, selection: $selection) {
            TableColumn("Title") { entry in ProjectListRow(entry: entry, column: .title) }
            TableColumn("Edited") { entry in ProjectListRow(entry: entry, column: .edited) }
                .width(min: 110, ideal: 140)
            TableColumn("Length") { entry in ProjectListRow(entry: entry, column: .length) }
                .width(min: 90, ideal: 110)
            TableColumn("To-dos") { entry in ProjectListRow(entry: entry, column: .todos) }
                .width(min: 60, ideal: 70)
            TableColumn("Folder") { entry in
                Text(entry.lastKnownURL.deletingLastPathComponent().path(percentEncoded: false))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .contextMenu(forSelectionType: LibraryEntry.ID.self) { ids in
            if let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                ProjectCard(entry: entry, open: { open(entry) }).menu
            }
        } primaryAction: { ids in
            if let id = ids.first, let entry = entries.first(where: { $0.id == id }) { open(entry) }
        }
    }
}

/// One cell, reading the project's summary in the background (as the cards do).
private struct ProjectListRow: View {
    enum Column { case title, edited, length, todos }
    let entry: LibraryEntry
    let column: Column
    @Environment(SlateAppModel.self) private var model
    @State private var summary: ProjectSummary?

    var body: some View {
        Group {
            switch column {
            case .title:
                HStack(spacing: 6) {
                    Image(systemName: model.library.missing.contains(entry.id) ? "questionmark.folder" : "film")
                        .foregroundStyle(.secondary)
                    Text(summary?.name ?? entry.folderName)
                    if entry.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                }
            case .edited:
                Text(summary?.lastEdited.map { $0.formatted(.relative(presentation: .named)) } ?? "—").foregroundStyle(.secondary)
            case .length:
                Text(summary?.lengthText ?? "—").monospacedDigit().foregroundStyle(.secondary)
            case .todos:
                Text(summary.map { "\($0.openTodos)" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .task(id: entry.lastKnownPath) {
            let url = entry.lastKnownURL
            summary = await Task.detached(priority: .utility) { ProjectSummary.load(at: url) }.value
        }
    }
}
