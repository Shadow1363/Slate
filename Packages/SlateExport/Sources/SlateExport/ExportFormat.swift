import Foundation
import SlateCore

/// The outputs Publish will produce. Milestone 1 only declares them; the
/// renderers arrive in Milestones 3 (PDF, Fountain, FDX, Markdown) and 10 (animatic).
public enum ExportFormat: String, CaseIterable, Sendable {
    case pdf
    case finalDraft = "fdx"
    case fountain
    case markdown = "md"
    case animatic = "mov"

    public var fileExtension: String { rawValue }

    /// Whether an exporter for this format exists yet.
    public var isAvailable: Bool { false }

    /// Where Publish writes this format inside a project.
    public func destinationFolder(in projectRoot: URL) -> URL {
        projectRoot.appending(path: ProjectLayout.exports, directoryHint: .isDirectory)
    }
}
