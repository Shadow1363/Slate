import Foundation
import SlateCore

/// The outputs Publish produces: the script formats, plus the animatic and
/// the boards PDF, which come from the storyboard.
public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case pdf
    case finalDraft = "fdx"
    case fountain
    case markdown = "md"
    case animatic = "mov"
    case boards

    public var id: String { rawValue }
    public var fileExtension: String { self == .boards ? "pdf" : rawValue }

    public var title: String {
        switch self {
        case .pdf: "PDF"
        case .finalDraft: "Final Draft (.fdx)"
        case .fountain: "Fountain"
        case .markdown: "Markdown"
        case .animatic: "Animatic (.mov)"
        case .boards: "Boards PDF"
        }
    }

    /// Made from the script text (the rest come from the storyboard).
    public var isScript: Bool { self != .animatic && self != .boards }
}

/// Everything Publish needs from a project, read through `ProjectStore`.
public struct ScriptSource: Sendable {
    public var projectName: String
    public var titlePage: String
    /// Act files in order: (file name, text).
    public var files: [(name: String, text: String)]
    public var settings: PublishSettings
    /// `script/production.json`, when the script is locked or in revision.
    public var production: ProductionFile?
    /// The current revision's baseline act files (name, text), for revision marks.
    public var baseline: [(name: String, text: String)]?

    public init(projectName: String, titlePage: String, files: [(name: String, text: String)], settings: PublishSettings,
                production: ProductionFile? = nil, baseline: [(name: String, text: String)]? = nil) {
        self.projectName = projectName
        self.titlePage = titlePage
        self.files = files
        self.settings = settings
        self.production = production
        self.baseline = baseline
    }

    public var parsed: [ParsedScript] { files.map { ScriptParser.parse($0.text) } }

    /// Locked numbers, locked pages and revision marks, if any.
    public func productionLayout(_ parsed: [ParsedScript]) -> ProductionLayout? {
        guard let production, !production.isEmpty else { return nil }
        return ProductionLayout.make(files: zip(files, parsed).map { (name: $0.0.name, parsed: $0.1) },
                                     production: production, baseline: baseline)
    }

    public var paginated: PaginatedScript {
        let parsed = parsed
        return Paginator(settings: settings, production: productionLayout(parsed)).paginate(parsed)
    }

    /// Locked scene numbers, for exports that carry them; nil when not locked.
    public var lockedLabels: [String]? {
        guard production?.scenesLocked == true else { return nil }
        return sceneLabels
    }

    /// Scene labels in script order (`14`, `14A`), locked or not.
    public var sceneLabels: [String] {
        let parsed = parsed
        return productionLayout(parsed)?.sceneLabels ?? SceneNumbering.labels(SceneNumbering.scenes(in: parsed), locked: nil)
    }
}

public enum Publisher {
    public static func pdf(_ source: ScriptSource) -> Data {
        PDFRenderer(
            paginated: source.paginated,
            titlePage: TitlePage.parse(source.titlePage),
            documentTitle: TitlePage.parse(source.titlePage).title.map { Emphasis.runs(in: $0).map(\.text).joined() } ?? source.projectName,
            emphasis: source.settings.emphasis
        ).render()
    }

    public static func data(for format: ExportFormat, _ source: ScriptSource) -> Data {
        switch format {
        case .pdf: pdf(source)
        case .fountain: Data(FountainExporter.export(titlePage: source.titlePage, files: source.files, sceneLabels: source.lockedLabels).utf8)
        case .finalDraft: Data(FDXExporter.export(titlePage: source.titlePage, files: source.files, sceneLabels: source.lockedLabels).utf8)
        case .markdown: Data(MarkdownExporter.export(titlePage: source.titlePage, files: source.files).utf8)
        case .animatic, .boards: Data()
        }
    }

    /// `exports/<Project> – 2026-11-22.pdf` (`<Project> – Boards – …` for boards), adding ` 2`, ` 3`… rather than overwriting.
    public static func destination(for format: ExportFormat, projectName: String, projectRoot: URL, date: Date = .now) -> URL {
        destination(kind: format == .boards ? "Boards" : nil, extension: format.fileExtension,
                    projectName: projectName, projectRoot: projectRoot, date: date)
    }

    /// `exports/<Project> – <kind> – 2026-11-22.<ext>`.
    public static func destination(kind: String?, extension ext: String, projectName: String, projectRoot: URL, date: Date = .now) -> URL {
        let folder = projectRoot.appending(path: ProjectLayout.exports, directoryHint: .isDirectory)
        let day = date.formatted(.iso8601.year().month().day())
        let base = "\(ProjectCreator.folderName(for: projectName))\(kind.map { " – \($0)" } ?? "") – \(day)"
        var url = folder.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Writes an export into the project's `exports/` folder and returns its URL.
    @discardableResult
    public static func export(_ format: ExportFormat, _ source: ScriptSource, projectRoot: URL) throws -> URL {
        let url = destination(for: format, projectName: source.projectName, projectRoot: projectRoot)
        try CoordinatedFileIO.write(data(for: format, source), to: url)
        return url
    }

    /// Reads a screenplay file for Import: Fountain, plain text, Markdown or Final Draft.
    public static func importScript(at url: URL) throws -> ImportedScript {
        let data = try CoordinatedFileIO.read(url)
        if url.pathExtension.lowercased() == "fdx" {
            return try FDXImporter.convert(data)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FileIOError.notUTF8(url.lastPathComponent)
        }
        return FountainImporter.convert(text)
    }

    /// Creates a project from an imported screenplay in `parent` and returns its folder.
    public static func createProject(from url: URL, in parent: URL) throws -> URL {
        let imported = try importScript(at: url)
        let title = TitlePage.parse(imported.titlePage).title.map { Emphasis.runs(in: $0).map(\.text).joined() }
            ?? url.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var name = title
        var n = 2
        while FileManager.default.fileExists(atPath: parent.appending(path: ProjectCreator.folderName(for: name)).path) {
            name = "\(title) \(n)"
            n += 1
        }
        let root = try ProjectCreator.create(title: name, template: .feature, in: parent)
        try imported.write(into: root)
        return root
    }
}
