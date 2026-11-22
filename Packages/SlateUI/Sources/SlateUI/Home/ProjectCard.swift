import AppKit
import SlateCore
import SwiftUI

struct ProjectCard: View {
    let entry: LibraryEntry
    let open: () -> Void

    @Environment(SlateAppModel.self) private var model
    @Environment(\.slateTheme) private var theme
    @State private var summary: ProjectSummary?

    private var isMissing: Bool { model.library.missing.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(summary?.name ?? entry.folderName)
                        .font(.headline)
                        .lineLimit(1)
                    if entry.pinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isMissing {
                    Button("Missing — Locate…", action: locate)
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Text(lastEditedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Page count and runtime need a full layout; they come with the cover images (M9).
                    Text(todoText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(theme.chrome.separator)))
        .opacity(isMissing ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) { if !isMissing { open() } }
        .contextMenu { menu }
        .help(entry.lastKnownPath)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !isMissing { open() } }
        .task(id: entry.lastKnownPath) { await loadSummary() }
    }

    private var cover: some View {
        ZStack {
            Rectangle().fill(Color(theme.storyboard.background))
            Image(systemName: isMissing ? "questionmark.folder" : "film")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
        }
        .frame(height: 120)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
    }

    @ViewBuilder private var menu: some View {
        Button("Open", action: open).disabled(isMissing)
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.lastKnownURL])
        }
        .disabled(isMissing)
        Button(entry.pinned ? "Unpin" : "Pin") {
            model.library.setPinned(!entry.pinned, for: entry.id)
        }
        if isMissing {
            Button("Locate…", action: locate)
        }
        Divider()
        Button("Remove from Library") {
            model.library.remove(entry.id)
        }
    }

    private var todoText: String {
        let open = summary?.openTodos ?? 0
        return open == 0 ? "No open to-dos" : "\(open) open \(open == 1 ? "to-do" : "to-dos")"
    }

    private var lastEditedText: String {
        guard let date = summary?.lastEdited else { return "Not opened yet" }
        return "Edited " + date.formatted(.relative(presentation: .named))
    }

    private func loadSummary() async {
        let url = entry.lastKnownURL
        summary = await Task.detached(priority: .utility) { ProjectSummary.load(at: url) }.value
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Where is “\(entry.folderName)” now? Choose its project folder."
        panel.prompt = "Locate"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.library.relocate(entry.id, to: url)
        } catch {
            SlateAppModel.showError("That folder isn't this project", error)
        }
    }
}
