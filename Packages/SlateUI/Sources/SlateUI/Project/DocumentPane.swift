import SlateCore
import SwiftUI

/// A file opened as plain text, with banners for outside changes.
struct DocumentPane: View {
    let store: ProjectStore
    let relativePath: String
    let close: () -> Void

    @State private var document: TextDocument?
    @State private var error: String?

    var body: some View {
        Group {
            if let document {
                DocumentEditor(store: store, document: document, close: close)
            } else if let error {
                ContentUnavailableView("Can't Open File", systemImage: "doc.badge.ellipsis", description: Text(error))
            } else if !ProjectLayout.isTextFile(relativePath) {
                ContentUnavailableView("Not a Text File", systemImage: "doc", description: Text("Slate shows media files in the Storyboard (Milestone 9)."))
            } else {
                ProgressView()
            }
        }
        .task(id: relativePath) {
            guard ProjectLayout.isTextFile(relativePath) else { return }
            do {
                document = try store.document(at: relativePath)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct DocumentEditor: View {
    let store: ProjectStore
    @Bindable var document: TextDocument
    let close: () -> Void

    @Environment(\.slateTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            DiskStateBanners(store: store, document: document, close: close)
            PlainTextEditor(text: $document.text, theme: theme)
            Divider()
            HStack {
                Text(document.relativePath)
                Spacer()
                Text(document.isDirty ? "Edited" : "Saved")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .navigationTitle(document.name)
    }
}

/// "Changed on disk" / "Deleted on disk" / save error banners for a document.
struct DiskStateBanners: View {
    let store: ProjectStore
    let document: TextDocument
    let close: () -> Void

    var body: some View {
        switch document.diskState {
        case .inSync:
            EmptyView()
        case .changedOnDisk:
            Banner(systemImage: "exclamationmark.triangle.fill", message: "“\(document.name)” changed on disk while you had unsaved edits.") {
                Button("Keep Mine") { store.keepMine(document) }
                Button("Load Theirs") { store.loadTheirs(document) }
            }
        case .deletedOnDisk:
            Banner(systemImage: "trash", message: "“\(document.name)” was deleted, moved or renamed outside Slate.") {
                Button("Save Again") { store.keepMine(document) }
                Button("Close") {
                    store.loadTheirs(document)
                    close()
                }
            }
        }
        if let error = document.lastError {
            Banner(systemImage: "xmark.octagon.fill", message: error) {}
        }
    }
}

struct Banner<Actions: View>: View {
    let systemImage: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.orange)
            Text(message).lineLimit(2)
            Spacer()
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
