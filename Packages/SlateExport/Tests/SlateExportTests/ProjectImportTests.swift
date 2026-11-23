import Foundation
import Testing
@testable import SlateCore
@testable import SlateExport

@Suite("Project import")
struct ProjectImportTests {
    static let vault = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/MarkdownVault", directoryHint: .isDirectory)

    @Test func kinds() throws {
        let temp = try TempDirectory()
        let project = try ProjectCreator.create(title: "Film", template: .blank, in: temp.url)
        #expect(ProjectImport.kind(of: project) == .slateFolder)
        #expect(ProjectImport.kind(of: Self.vault) == .markdownFolder)
        #expect(ProjectImport.kind(of: project.appending(path: "script/script.md")) == .screenplay)
        let zip = temp.url.appending(path: "a.zip")
        try Data("PK".utf8).write(to: zip)
        #expect(ProjectImport.kind(of: zip) == .zip)
        #expect(ProjectImport.kind(of: temp.url.appending(path: "storyboard")) == nil)
        #expect(ProjectImport.kind(of: temp.url.appending(path: "nothing-here")) == nil)
    }

    @Test func markdownVaultBecomesUniverse() async throws {
        let temp = try TempDirectory()
        let root = try ProjectImport.importMarkdownFolder(Self.vault, into: temp.url)
        #expect(root.lastPathComponent == "MarkdownVault")
        let universe = root.appending(path: "universe")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: universe.appending(path: "People/Mara Voss.md").path))
        #expect(fm.fileExists(atPath: universe.appending(path: "The Brass Key.md").path))
        #expect(fm.fileExists(atPath: universe.appending(path: "Boards/Plot.canvas").path))
        #expect(fm.fileExists(atPath: universe.appending(path: "key.png").path))
        #expect(fm.fileExists(atPath: universe.appending(path: "draft 2.md").path)) // the project's draft.md is kept
        #expect(!fm.fileExists(atPath: universe.appending(path: ".obsidian").path))
        let key = try String(contentsOf: universe.appending(path: "The Brass Key.md"), encoding: .utf8)
        #expect(key.contains("[[Mara Voss|Mara]]"))
        // It opens, and the links resolve.
        let store = try await MainActor.run { try ProjectStore(rootURL: root, autosaveDelay: nil) }
        let paths = await MainActor.run { store.files.values.flatMap { $0 }.map(\.relativePath) }
        #expect(paths.contains("universe/People/Mara Voss.md"))
    }

    @Test func zipRoundTripMakesASeparateCopy() throws {
        let temp = try TempDirectory()
        let original = try ProjectCreator.create(title: "Harbour", template: .short, in: temp.url)
        let zip = temp.url.appending(path: "Harbour.zip")
        try ProjectFolders.zip(original, to: zip)
        let imports = temp.url.appending(path: "Imports")
        let copy = try ProjectImport.importZip(zip, into: imports)
        #expect(copy.lastPathComponent == "Harbour")
        let a = try ProjectManifest.decode(Data(contentsOf: original.appending(path: "project.json")))
        let b = try ProjectManifest.decode(Data(contentsOf: copy.appending(path: "project.json")))
        #expect(a.name == b.name)
        #expect(a.id != b.id)
        // A second import doesn't overwrite the first.
        #expect(try ProjectImport.importZip(zip, into: imports).lastPathComponent == "Harbour 2")
        let notProject = temp.url.appending(path: "notes.zip")
        try ProjectFolders.zip(Self.vault, to: notProject)
        #expect(throws: ProjectImport.ImportError.noProjectInZip) { try ProjectImport.importZip(notProject, into: imports) }
    }
}
