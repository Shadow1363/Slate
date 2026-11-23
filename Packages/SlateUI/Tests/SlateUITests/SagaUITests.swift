import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Sagas: several films in one project")
struct SagaUITests {
    private func makeWorkspace(title: String = "Tidewater") throws -> ScriptWorkspace {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SlateSaga-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try ProjectCreator.create(title: title, template: .blank, in: folder)
        try? FileManager.default.removeItem(at: root.appending(path: "script/script.md"))
        try Data("# ACT ONE\n\nINT. KITCHEN - NIGHT {#s001}\n\nRain.\n\nEXT. ROOF - DAWN {#s002}\n\nWind.\n".utf8)
            .write(to: root.appending(path: "script/01-act-one.md"))
        try Data("{\"revisions\": []}\n".utf8).write(to: root.appending(path: "script/production.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "universe/canvases"), withIntermediateDirectories: true)
        try Data(##"{"nodes":[{"id":"a","type":"file","file":"script/01-act-one.md","subpath":"#s001","x":0,"y":0,"width":200,"height":100}],"edges":[]}"##.utf8)
            .write(to: root.appending(path: "universe/canvases/web.canvas"))
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let workspace = ScriptWorkspace(store: store)
        workspace.refreshFiles()
        return workspace
    }

    private func exists(_ workspace: ScriptWorkspace, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: workspace.store.rootURL.appending(path: path).path)
    }

    @Test func theFirstNewFilmMakesASaga() throws {
        let workspace = try makeWorkspace()
        #expect(!workspace.isSaga)
        try workspace.saveSnapshot(name: "Before the sequel")
        #expect(workspace.publishName == "Tidewater")

        let sequel = try workspace.newFilm(title: "Slack Water", date: Date(timeIntervalSince1970: 1_795_400_000))
        #expect(sequel.folder == "script/02 Slack Water")
        #expect(workspace.films.map(\.folder) == ["script/01 Tidewater", "script/02 Slack Water"])
        #expect(workspace.isSaga)
        #expect(workspace.film == sequel)
        #expect(workspace.publishName == "Slack Water")

        // The first film moved into its folder; the margin stayed shared.
        for path in ["script/01 Tidewater/01-act-one.md", "script/01 Tidewater/title-page.md", "script/01 Tidewater/production.json",
                     "script/margin/todos.md", "script/02 Slack Water/title-page.md", "script/02 Slack Water/01-act-one.md"] {
            #expect(exists(workspace, path), "missing \(path)")
        }
        #expect(!exists(workspace, "script/01-act-one.md"))
        #expect(try workspace.store.readText(at: "universe/canvases/web.canvas").contains(#""file":"script/01 Tidewater/01-act-one.md""#))
        #expect(!exists(workspace, "script/title-page.md"))
        #expect(exists(workspace, "script/01 Tidewater/.snapshots"))
        #expect(try workspace.store.readText(at: "script/02 Slack Water/title-page.md").hasPrefix("Title: Slack Water\n"))

        // The new film is empty; the first is an outline the storyboard and IDs can see.
        #expect(workspace.scriptFiles.map(\.relativePath) == ["script/02 Slack Water/01-act-one.md"])
        #expect(workspace.book.scenes.isEmpty)
        #expect(workspace.otherFilms.map(\.film.title) == ["Tidewater"])
        #expect(workspace.otherFilmSceneIDs == ["s001", "s002"])
        #expect(workspace.snapshots.isEmpty)

        // New scenes never reuse another film's IDs.
        workspace.appendSceneStub(heading: "EXT. HARBOUR - DAY")
        #expect(workspace.book.scenes.map(\.scene.sceneID) == ["s003"])
        #expect(workspace.sceneOrder == ["s001", "s002", "s003"])
        #expect(workspace.film(containingScene: "s001")?.title == "Tidewater")

        // Each film keeps its own production.json.
        workspace.lockScenes()
        #expect(exists(workspace, "script/02 Slack Water/production.json"))
        #expect(workspace.production.scenes?.map(\.id) == ["s003"])

        workspace.select(film: workspace.films[0])
        #expect(workspace.book.scenes.map(\.scene.sceneID) == ["s001", "s002"])
        #expect(workspace.production.scenes == nil)
        #expect(workspace.snapshots.map(\.name) == ["Before the sequel"])
        #expect(workspace.currentFile == "script/01 Tidewater/01-act-one.md")
        workspace.selectAdjacentFilm(1)
        #expect(workspace.film.title == "Slack Water")
        // A to-do anchored in the other film takes you there.
        workspace.reveal(sceneID: "s002", quote: nil)
        #expect(workspace.film.title == "Tidewater")
        #expect(workspace.selectedRow == "scene:s002")
    }

    @Test func aCopiedFilmGetsNewSceneIDs() throws {
        let workspace = try makeWorkspace()
        try workspace.newFilm(title: "Copy")
        // Pasting the first film's scenes into the second keeps their text, not their IDs.
        let path = "script/02 Copy/01-act-one.md"
        let document = try #require(workspace.store.documents[path])
        document.text = try workspace.store.readText(at: "script/01 Tidewater/01-act-one.md")
        workspace.store.save(document)
        workspace.refreshFiles()
        #expect(workspace.book.scenes.map(\.scene.sceneID) == ["s003", "s004"])
        #expect(try workspace.store.readText(at: "script/01 Tidewater/01-act-one.md").contains("{#s001}"))
    }

    @Test func renameAndTrashFilms() throws {
        let workspace = try makeWorkspace()
        try workspace.newFilm(title: "Second")
        try workspace.newFilm(title: "Third")
        #expect(workspace.films.map(\.folderName) == ["01 Tidewater", "02 Second", "03 Third"])
        try workspace.rename(film: workspace.film, to: "The End")
        #expect(workspace.film.folder == "script/03 The End")
        #expect(workspace.currentFile == "script/03 The End/01-act-one.md")
        let second = try #require(workspace.films.first { $0.title == "Second" })
        workspace.select(film: second)
        try workspace.trash(film: second)
        #expect(workspace.films.map(\.title) == ["Tidewater", "The End"])
        #expect(workspace.film.title == "Tidewater")
    }

    @Test func theStoryboardFollowsTheFilm() throws {
        let h = try SessionHarness()
        let session = h.session
        let board = session.storyboard
        #expect(board.rows.contains { $0.id == "s014" && $0.frames.count == 3 })

        try session.script.newFilm(title: "Second Film")
        session.filesChanged()
        // The first film's boards aren't missing: they belong to another film.
        #expect(board.rows.isEmpty)
        #expect(board.plan.missing.isEmpty)
        #expect(board.plan.boarded["s014"] != nil)
        session.script.appendSceneStub(heading: "INT. NEW ROOM - DAY")
        session.filesChanged()
        #expect(board.rows.map(\.kind) == [.scene])

        // Opening a scene of another film switches to it.
        session.open(sceneID: "s014")
        #expect(session.script.film.title == "SampleProject" || session.script.film.folderName.hasPrefix("01 "))
        #expect(board.rows.contains { $0.id == "s014" && $0.frames.count == 3 })
        #expect(session.area == .script)
    }
}
