import AppKit
import Foundation
import PDFKit
import Testing
@testable import SlateCore
@testable import SlateExport
@testable import SlateUI

@MainActor
@Suite("Production workspace")
struct ProductionUITests {
    static let script = """
    INT. KITCHEN - NIGHT {#s001}

    Rain hammers the window.

    MARA
    I haven't opened it yet.

    EXT. ROOF - DAWN {#s002}

    Wind.

    INT. CELLAR - NIGHT {#s003}

    Dust.
    """

    private func makeWorkspace(_ text: String = script) throws -> (ScriptWorkspace, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SlateProd-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try ProjectCreator.create(title: "Production", template: .short, in: folder)
        try Data(text.utf8).write(to: root.appending(path: "script/script.md"))
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let workspace = ScriptWorkspace(store: store)
        workspace.refreshFiles()
        return (workspace, root)
    }

    private func edit(_ workspace: ScriptWorkspace, _ change: (inout String) -> Void) throws {
        let document = try workspace.store.document(at: "script/script.md")
        var text = document.text
        change(&text)
        document.text = text
        workspace.store.save(document)
    }

    @Test func lockingNumbersLettersNewScenesAndOmitsCutOnes() throws {
        let (workspace, root) = try makeWorkspace()
        #expect(workspace.production.isEmpty)
        #expect(workspace.productionStatus == nil)
        workspace.lockScenes()
        let file = try ProductionFile(text: String(contentsOf: root.appending(path: ProductionFile.path), encoding: .utf8))
        #expect(file.scenes?.map(\.number) == ["1", "2", "3"])
        #expect(workspace.productionStatus == "Scenes locked")

        // Cut the roof, add a scene after the kitchen.
        try edit(workspace) {
            $0 = $0.replacingOccurrences(of: "EXT. ROOF - DAWN {#s002}\n\nWind.\n\n", with: "INT. HALL - NIGHT {#s004}\n\nSteps.\n\n")
        }
        #expect(workspace.sceneLabels == ["1", "1A", "3"])
        let page = workspace.scriptSource().paginated.pages[0]
        #expect(page.rows.compactMap(\.line.sceneNumber) == ["1", "1A", "2", "3"])
        #expect(page.rows.contains { $0.line.text == "OMITTED" })
        // Exports carry the locked numbers.
        let fountain = String(decoding: Publisher.data(for: .fountain, workspace.scriptSource()), as: UTF8.self)
        #expect(fountain.contains("INT. HALL - NIGHT #1A#"))
        let fdx = String(decoding: Publisher.data(for: .finalDraft, workspace.scriptSource()), as: UTF8.self)
        #expect(fdx.contains("Number=\"1A\""))

        // Re-locking keeps the omitted scene.
        workspace.lockScenes()
        #expect(workspace.production.scenes?.map(\.number) == ["1", "1A", "2", "3"])
        workspace.updateProduction { $0.scenes = nil }
        #expect(workspace.sceneLabels == ["1", "2", "3"])
    }

    @Test func lockingPagesRecordsAnchors() throws {
        let (workspace, _) = try makeWorkspace()
        workspace.lockPages()
        let anchors = try #require(workspace.production.pages)
        #expect(anchors.map(\.page) == ["1"])
        #expect(anchors[0].at == "start")
        #expect(workspace.productionStatus == "Pages locked")
    }

    @Test func revisionsSnapshotAndMarkChanges() throws {
        let (workspace, root) = try makeWorkspace()
        workspace.lockScenes()
        workspace.startRevision(date: Date(timeIntervalSince1970: 1_795_400_000))
        let revision = try #require(workspace.production.currentRevision)
        #expect(revision.color == .blue)
        let baseline = root.appending(path: "script/revisions/01 blue/script.md")
        #expect(FileManager.default.fileExists(atPath: baseline.path))
        #expect(workspace.baseline?.map(\.name) == ["script.md"])
        #expect(workspace.scriptFiles.map(\.name) == ["script.md"]) // a baseline is never an act file
        #expect(workspace.production.nextColor == .pink)

        // Nothing changed yet: no marks.
        #expect(workspace.scriptSource().paginated.pages.allSatisfy { $0.revision == nil })
        try edit(workspace) { $0 = $0.replacingOccurrences(of: "Wind.", with: "Wind howls.") }
        workspace.refreshProduction()
        let page = workspace.scriptSource().paginated.pages[0]
        #expect(page.rows.filter(\.line.revised).map(\.line.text) == ["Wind howls."])
        #expect(page.revision?.color == .blue)

        workspace.clearRevisions()
        #expect(workspace.production.revisions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: baseline.path))
        #expect(workspace.production.scenesLocked)
    }

    @Test func reportsAndSidesGoToExports() throws {
        let (workspace, _) = try makeWorkspace()
        let csvURL = try workspace.writeReport(.scenes, csv: true)
        #expect(csvURL.lastPathComponent.contains("Scene List"))
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        #expect(csv.contains("1,INT,KITCHEN,NIGHT"))
        #expect(csv.contains("3,INT,CELLAR,NIGHT"))
        let pdfURL = try workspace.writeReport(.characters, csv: false)
        #expect(PDFDocument(url: pdfURL)?.string?.contains("MARA") == true)

        let sides = try workspace.writeSides(sceneIDs: ["s002"])
        let document = try #require(PDFDocument(url: sides))
        #expect(document.pageCount == 1) // the title page is left out
        #expect(document.string?.contains("SIDES · Scene 2") == true)
    }
}
