import Foundation
import PDFKit
import Testing
@testable import SlateCore
@testable import SlateExport
@testable import SlateUI

@MainActor
@Suite("Script workspace publishing")
struct ScriptWorkspaceTests {
    private func makeWorkspace(_ text: String) throws -> (ScriptWorkspace, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SlateWS-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try ProjectCreator.create(title: "Workspace", template: .short, in: folder)
        try Data(text.utf8).write(to: root.appending(path: "script/script.md"))
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        return (ScriptWorkspace(store: store), root)
    }

    @Test func timingsBecomeExactAfterTypingStops() async throws {
        let filler = (1...26).map { "Line \($0)." }.joined(separator: "\n\n")
        let (workspace, _) = try makeWorkspace("INT. A {#s001}\n\n" + filler + "\n\nINT. B {#s002}\n\nShort.\n")
        #expect(!workspace.book.isExact)
        let exact = await waitFor { workspace.book.isExact }
        #expect(exact)
        #expect(workspace.book.scenes.map(\.eighths) == [8, 1])
        #expect(workspace.book.pageCount == 2)

        // An edit drops back to the estimate until the paginator catches up.
        workspace.store.documents["script/script.md"]?.text += "\nMore."
        #expect(!workspace.book.isExact)
        #expect(await waitFor { workspace.book.isExact })
    }

    @Test func publishSettingsAreSavedPerProject() throws {
        let (workspace, root) = try makeWorkspace("INT. A {#s001}\n\nGo.\n")
        workspace.updatePublishSettings { $0.sceneNumbers = false; $0.pageSize = .a4 }
        let manifest = try ProjectManifest.decode(Data(contentsOf: root.appending(path: "project.json")))
        #expect(PublishSettings(manifest: manifest).sceneNumbers == false)
        #expect(manifest.pageSize == .a4)
        #expect(workspace.scriptSource().settings.pageSize == .a4)
    }

    @Test func exportsEveryFormatIntoTheProject() throws {
        let (workspace, root) = try makeWorkspace("INT. KITCHEN - NIGHT {#s001}\n\nRain.\n\nMARA\nHi.\n")
        for format in ExportFormat.allCases where format.isAvailable {
            let url = try workspace.export(format)
            #expect(url.deletingLastPathComponent().standardizedFileURL == root.appending(path: "exports").standardizedFileURL)
        }
        let pdf = try #require(workspace.store.files[.script]).isEmpty == false
        #expect(pdf)
        let exported = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "exports").path)
        #expect(Set(exported.map { ($0 as NSString).pathExtension }) == ["pdf", "fdx", "fountain", "md"])
        let pdfURL = root.appending(path: "exports").appending(path: try #require(exported.first { $0.hasSuffix(".pdf") }))
        #expect(PDFDocument(url: pdfURL)?.page(at: 1)?.string?.contains("INT. KITCHEN - NIGHT") == true)
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
