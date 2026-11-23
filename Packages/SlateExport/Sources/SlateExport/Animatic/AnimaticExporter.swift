@preconcurrency import AVFoundation
import Foundation
import SlateCore

/// Writes the animatic as an H.264 `.mov` with overlays burned in.
public enum AnimaticExporter {
    public static func export(_ timeline: AnimaticTimeline, root: URL, overlays: AnimaticOverlays, to url: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let composed = try await AnimaticComposer.compose(timeline, root: root, overlays: overlays)
        try await export(composed, to: url, progress: progress)
    }

    public static func export(_ composed: AnimaticComposition, to url: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let session = AVAssetExportSession(asset: composed.composition, presetName: AVAssetExportPreset1920x1080) else {
            throw AnimaticError.cannotExport("this Mac can't write 1080p H.264")
        }
        session.videoComposition = composed.videoComposition
        session.audioMix = composed.audioMix
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let box = SessionBox(session)
        let watcher = Task {
            for await state in box.session.states(updateInterval: 0.2) {
                if case .exporting(let fraction) = state { progress(fraction.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await withTaskCancellationHandler {
            try await box.session.export(to: url, as: .mov)
        } onCancel: {
            box.session.cancelExport()
        }
        progress(1)
    }

    /// The session is only touched through its thread-safe calls.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    /// `exports/<Project> – 2026-11-22.mov`.
    public static func destination(projectName: String, projectRoot: URL) -> URL {
        Publisher.destination(for: .animatic, projectName: projectName, projectRoot: projectRoot)
    }
}
