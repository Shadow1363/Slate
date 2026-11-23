import Foundation
import Testing
@testable import SlateCore

@Suite("Films (sagas)")
struct FilmsTests {
    @Test func aSingleFilmIsScriptItself() {
        let films = Films.films(paths: ["script/title-page.md", "script/01-act-one.md", "script/margin/todos.md", "script/production.json"],
                                projectName: "Harbour")
        #expect(films == [Film(folder: "script", title: "Harbour")])
        #expect(films[0].isRoot)
        // An empty script folder is still one film.
        #expect(Films.films(paths: ["script/margin/notes.md"], projectName: "Empty").map(\.folder) == ["script"])
    }

    @Test func filmFoldersMakeASaga() {
        let paths = [
            "script/margin/todos.md", "script/revisions/01 blue/01-act-one.md",
            "script/10 Coda/script.md",
            "script/02 Slack Water/title-page.md", "script/02 Slack Water/01-act-one.md", "script/02 Slack Water/production.json",
            "script/02 Slack Water/revisions/01 blue/01-act-one.md",
            "script/01 Tidewater/02-act-two.md", "script/01 Tidewater/01-act-one.md", "script/01 Tidewater/notes/idea.md",
        ]
        let films = Films.films(paths: paths, projectName: "Saga")
        #expect(films.map(\.folder) == ["script/01 Tidewater", "script/02 Slack Water", "script/10 Coda"])
        #expect(films.map(\.title) == ["Tidewater", "Slack Water", "Coda"])
        #expect(Films.actFiles(paths: paths, in: films[0]) == ["script/01 Tidewater/01-act-one.md", "script/01 Tidewater/02-act-two.md"])
        #expect(Films.actFiles(paths: paths, in: films[1]) == ["script/02 Slack Water/01-act-one.md"])
        #expect(films[1].titlePagePath == "script/02 Slack Water/title-page.md")
        #expect(films[1].productionPath == "script/02 Slack Water/production.json")
        #expect(films[1].snapshotsFolder == "script/02 Slack Water/.snapshots")

        #expect(Films.film(containing: "script/02 Slack Water/01-act-one.md", in: films) == films[1])
        #expect(Films.film(containing: "script/margin/todos.md", in: films) == nil)
        #expect(Films.isActFile("script/02 Slack Water/01-act-one.md"))
        #expect(Films.isActFile("script/01-act-one.md"))
        #expect(!Films.isActFile("script/02 Slack Water/title-page.md"))
        #expect(!Films.isActFile("script/margin/todos.md"))
        #expect(!Films.isActFile("script/01 Tidewater/notes/idea.md"))
        #expect(Films.isRevisionCopy("script/revisions/01 blue/01-act-one.md"))
        #expect(Films.isRevisionCopy("script/02 Slack Water/revisions/01 blue/01-act-one.md"))
        #expect(!Films.isRevisionCopy("script/02 Slack Water/01-act-one.md"))

        // A film's act files are scenes to the link index; title pages and margins aren't.
        #expect(IndexedFile.isIndexed("script/02 Slack Water/01-act-one.md"))
        #expect(!IndexedFile.isIndexed("script/02 Slack Water/title-page.md"))
    }

    @Test func actFilesLeftInScriptJoinASaga() {
        // Act files in script/ next to film folders are the first film.
        let films = Films.films(paths: ["script/script.md", "script/02 Sequel/script.md"], projectName: "Mixed")
        #expect(films.map(\.folder) == ["script", "script/02 Sequel"])
        #expect(films[0].title == "Mixed")
    }

    @Test func folderNamesAndTitles() {
        #expect(Films.folderName(number: 3, title: "Return: Part/Two") == "03 Return- Part-Two")
        #expect(Films.title(fromFolderName: "03 Return- Part-Two") == "Return- Part-Two")
        #expect(Films.title(fromFolderName: "04-the-end") == "the-end")
        #expect(Films.title(fromFolderName: "1917") == "1917")
        #expect(Films.title(fromFolderName: "Prequel") == "Prequel")
    }

    @Test func becomingASagaMovesTheScript() {
        let paths = ["script/title-page.md", "script/01-act-one.md", "script/02-act-two.md", "script/production.json",
                     "script/revisions/01 blue/01-act-one.md", "script/revisions/01 blue/02-act-two.md",
                     "script/margin/todos.md", "script/margin/notes.md"]
        let plan = Films.sagaMoves(paths: paths, projectName: "Tidewater", hiddenFolders: [".snapshots"])
        #expect(plan.film.folder == "script/01 Tidewater")
        #expect(plan.moves.map(\.from) == ["script/.snapshots", "script/01-act-one.md", "script/02-act-two.md", "script/production.json",
                                           "script/revisions", "script/title-page.md"])
        #expect(plan.moves.allSatisfy { $0.to == "script/01 Tidewater/" + ($0.from as NSString).lastPathComponent })
    }

    @Test func homeCardsAddUpEveryFilm() throws {
        let folder = try TempFolder()
        let root = try ProjectCreator.create(title: "Saga", template: .blank, in: folder.url)
        let fm = FileManager.default
        try fm.removeItem(at: root.appending(path: "script/script.md"))
        let scene = (1...30).map { "Line \($0) of the action, long enough to take a printed line." }.joined(separator: "\n\n")
        for (film, id) in [("01 First", "s001"), ("02 Second", "s002")] {
            let url = root.appending(path: "script/\(film)")
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("INT. ROOM - DAY {#\(id)}\n\n\(scene)\n".utf8).write(to: url.appending(path: "script.md"))
        }
        let onDisk = Films.onDisk(root: root, projectName: "Saga")
        #expect(onDisk.map(\.film.title) == ["First", "Second"])
        #expect(onDisk.map(\.files.count) == [1, 1])

        let summary = try #require(ProjectSummary.load(at: root))
        #expect(summary.films == 2)
        #expect(summary.pages >= 2)
        #expect(summary.lengthText?.hasPrefix("2 films · ") == true)
    }

    @Test func snapshotsCanLiveInAFilm() throws {
        let folder = try TempFolder()
        let snapshot = try ScriptSnapshot.save(name: "Draft", files: [(name: "script.md", text: "INT. A - DAY\n")], in: folder.url,
                                               folder: "script/02 Sequel/.snapshots")
        #expect(snapshot.url.path.contains("script/02 Sequel/.snapshots/"))
        #expect(ScriptSnapshot.all(in: folder.url, folder: "script/02 Sequel/.snapshots").count == 1)
        #expect(ScriptSnapshot.all(in: folder.url).isEmpty)
    }

    @Test func outlinesListSceneIDs() {
        let parsed = ScriptParser.parse("INT. A - DAY {#s004}\n\nRain.\n\nEXT. B - NIGHT {#s005}\n\nWind.\n")
        let outline = FilmOutline(film: Film(folder: "script/02 B", title: "B"), parsed: [parsed])
        #expect(outline.scenes.map(\.id) == ["s004", "s005"])
        #expect(outline.scenes[1].heading == "EXT. B - NIGHT")
    }

    @Test func canvasCardsFollowMovedActFiles() {
        let canvas = ##"{"nodes":[{"type":"file","file":"script/01-act-one.md","subpath":"#s003"},{"type":"file","file":"script/revisions/01 blue/x.md"},{"type":"file","file":"script/01-act-one.mdx"}]}"##
        let moved = Films.rewritingPaths(in: canvas, moves: [("script/01-act-one.md", "script/01 T/01-act-one.md"), ("script/revisions", "script/01 T/revisions")])
        #expect(moved.contains(#""file":"script/01 T/01-act-one.md""#))
        #expect(moved.contains(#""file":"script/01 T/revisions/01 blue/x.md""#))
        #expect(moved.contains(#""file":"script/01-act-one.mdx""#))
    }
}
