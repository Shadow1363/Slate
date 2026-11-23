import AppKit
import Observation
import SlateCore
import SlateExport
import SwiftUI

/// A storyboard export running in the background, shown as a bar at the foot of the window.
@MainActor
@Observable
final class ExportJob: Identifiable {
    let id = UUID()
    let title: String
    var progress: Double = 0
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String) { self.title = title }

    func cancel() { task?.cancel() }
}

extension ProjectSession {
    // MARK: Watching

    /// Opens the player window on a range and starts playing.
    func watch(_ range: AnimaticRange = .film) {
        let controller = animaticWindow ?? {
            let model = AnimaticPlayerModel(storyboard: storyboard, root: store.rootURL)
            model.onSelect = { [weak self] ref in
                guard let self else { return }
                area = .storyboard
                storyboard.focusedRow = (storyboard.rows + storyboard.orphanRows).first { $0.folder?.path == ref.folder }?.id
                storyboard.select(ref)
            }
            let controller = AnimaticWindowController(model: model, title: "\(store.manifest.name) — Animatic")
            animaticWindow = controller
            return controller
        }()
        controller.model.play(range)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func closeAnimatic() {
        animaticWindow?.close()
        animaticWindow = nil
    }

    // MARK: Exporting

    /// Script formats go through Publish; the animatic and boards come from the storyboard.
    func publish(_ format: ExportFormat) {
        switch format {
        case .animatic: exportAnimatic()
        case .boards: exportBoards(BoardsPDF.Layout(rawValue: UserDefaults.standard.integer(forKey: "boards.perPage")) ?? .four)
        default: script.publish(format)
        }
    }

    /// Writes the whole film to `exports/` as H.264 .mov, with the player's overlays burned in.
    func exportAnimatic() {
        run("Exporting animatic") { [self] job in
            let timeline = storyboard.timeline(.film, clipLengths: await storyboard.loadClipLengths())
            let url = AnimaticExporter.destination(projectName: store.manifest.name, projectRoot: store.rootURL)
            try await AnimaticExporter.export(timeline, root: store.rootURL, overlays: AnimaticPlayerModel.savedOverlays, to: url) { fraction in
                Task { @MainActor in job.progress = fraction }
            }
            return url
        }
    }

    /// Writes the boards PDF (2, 4 or 6 frames a page) to `exports/`.
    func exportBoards(_ layout: BoardsPDF.Layout) {
        UserDefaults.standard.set(layout.rawValue, forKey: "boards.perPage")
        run("Exporting boards") { [self] _ in
            let timeline = storyboard.timeline(.film, clipLengths: await storyboard.loadClipLengths())
            guard !timeline.segments.isEmpty else { throw AnimaticError.empty }
            let boards = BoardsPDF(timeline: timeline, projectName: store.manifest.name, layout: layout,
                                   pageSize: script.publishSettings.pageSize)
            let data = await boards.render(root: store.rootURL)
            let url = BoardsPDF.destination(projectName: store.manifest.name, projectRoot: store.rootURL)
            try CoordinatedFileIO.write(data, to: url)
            return url
        }
    }

    private func run(_ title: String, _ work: @escaping @MainActor (ExportJob) async throws -> URL) {
        guard exportJob == nil else { return }
        store.saveAll()
        let job = ExportJob(title: title)
        exportJob = job
        job.task = Task { [weak self] in
            defer { self?.exportJob = nil }
            do {
                let url = try await work(job)
                self?.store.rescan()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                // Cancel stops the export with an error of its own; that one isn't news.
                if !Task.isCancelled { SlateAppModel.showError("Couldn't export", error) }
            }
        }
    }
}

/// The export bar: what's running, how far along, and Cancel.
struct ExportJobBar: View {
    let job: ExportJob

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: job.progress).frame(width: 160)
            Text(job.title + "…").font(.callout)
            Text("\(Int(job.progress * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button("Cancel") { job.cancel() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 1)
        .padding(.bottom, 14)
    }
}
