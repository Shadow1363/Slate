import Foundation
import Testing
@testable import SlateCore

@Suite("Library folders")
struct ProjectFolderTests {
    @Test func renameDuplicateAndZip() throws {
        let folder = try TempFolder()
        let root = try ProjectCreator.create(title: "Harbour", template: .short, in: folder.url)
        try Data("cached".utf8).write(to: root.appending(path: ".slate/index.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "exports"), withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: root.appending(path: "exports/old.pdf"))

        let renamed = try ProjectFolders.rename(root, to: "Lighthouse")
        #expect(renamed.lastPathComponent == "Lighthouse")
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let manifest = try ProjectManifest.decode(Data(contentsOf: renamed.appending(path: "project.json")))
        #expect(manifest.name == "Lighthouse")
        // Renaming to its own name changes nothing; to a taken name adds " 2".
        #expect(try ProjectFolders.rename(renamed, to: "Lighthouse") == renamed)
        _ = try ProjectCreator.create(title: "Taken", template: .blank, in: folder.url)
        let second = try ProjectFolders.rename(renamed, to: "Taken")
        #expect(second.lastPathComponent == "Taken 2")

        let copy = try ProjectFolders.duplicate(second)
        #expect(copy.lastPathComponent == "Taken copy")
        let copied = try ProjectManifest.decode(Data(contentsOf: copy.appending(path: "project.json")))
        #expect(copied.name == "Taken copy")
        #expect(copied.id != manifest.id)
        #expect(!FileManager.default.fileExists(atPath: copy.appending(path: "exports/old.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: copy.appending(path: ".slate/index.json").path))
        #expect(FileManager.default.fileExists(atPath: copy.appending(path: "script").path))

        let zip = folder.url.appending(path: "Taken.zip")
        try ProjectFolders.zip(second, to: zip)
        let data = try Data(contentsOf: zip)
        #expect(data.prefix(2) == Data("PK".utf8))
        let listing = String(decoding: data, as: UTF8.self)
        #expect(listing.contains("project.json"))
        #expect(!listing.contains("old.pdf"))
    }

    @MainActor
    @Test func watchedFoldersAddAndRemove() throws {
        let folder = try TempFolder()
        let support = folder.url.appending(path: "support")
        let watched = folder.url.appending(path: "Films")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        _ = try ProjectCreator.create(title: "Found", template: .blank, in: watched)
        let library = ProjectLibrary(directory: support, defaultWatchedFolder: folder.url.appending(path: "Default"))
        library.addWatchedFolder(watched)
        #expect(library.watchedFolders.count == 2)
        #expect(library.entries.map(\.folderName) == ["Found"])
        library.addWatchedFolder(watched)
        #expect(library.watchedFolders.count == 2)
        // It's remembered.
        let reloaded = ProjectLibrary(directory: support, defaultWatchedFolder: folder.url.appending(path: "Default"))
        #expect(reloaded.watchedFolders.map(\.lastPathComponent).contains("Films"))
        reloaded.removeWatchedFolder(watched)
        #expect(reloaded.watchedFolders.count == 1)
        #expect(reloaded.entries.count == 1) // its projects stay in the library
    }
}

@Suite("Scene editing")
struct SceneEditingTests {
    static let act1 = """
    # ACT ONE

    INT. KITCHEN - NIGHT {#s001 dur=1:00}

    Rain.

    EXT. ROOF - DAWN {#s002}

    Wind.
    """

    @Test func colourLabelsLiveInTheTag() {
        let labelled = SceneEditing.settingAttribute("color", to: "blue", headingLine: 2, in: Self.act1)
        #expect(labelled.contains("INT. KITCHEN - NIGHT {#s001 dur=1:00 color=blue}"))
        let parsed = ScriptParser.parse(labelled)
        #expect(parsed.scenes[0].color == .blue)
        #expect(parsed.scenes[0].durationOverride == 60)
        let changed = SceneEditing.settingAttribute("color", to: "red", headingLine: 2, in: labelled)
        #expect(changed.contains("{#s001 dur=1:00 color=red}"))
        #expect(SceneEditing.settingAttribute("color", to: nil, headingLine: 2, in: changed) == Self.act1)
        // Publish never prints it.
        let page = Paginator().paginate([parsed]).pages[0]
        #expect(!page.rows.contains { $0.line.text.contains("color") })
    }

    @Test func movingAScene() throws {
        let (rest, scene) = try #require(SceneEditing.removingScene(0, from: Self.act1))
        #expect(scene == "INT. KITCHEN - NIGHT {#s001 dur=1:00}\n\nRain.\n\n")
        #expect(ScriptParser.parse(rest).scenes.map(\.sceneID) == ["s002"])
        let act2 = "# ACT TWO\n\nINT. CELLAR - DAY {#s003}\n\nDust.\n"
        let atStart = SceneEditing.insertingScene(scene, at: 0, in: act2)
        #expect(ScriptParser.parse(atStart).scenes.map(\.sceneID) == ["s001", "s003"])
        let atEnd = SceneEditing.insertingScene(scene, at: 9, in: act2)
        #expect(ScriptParser.parse(atEnd).scenes.map(\.sceneID) == ["s003", "s001"])
        #expect(atEnd.hasSuffix("Rain.\n"))
        #expect(SceneEditing.removingScene(5, from: Self.act1) == nil)
    }

    @Test func duplicateIDsAcrossFilesAreRenumbered() {
        let first = ScriptParser.parse(Self.act1)
        let second = ScriptParser.parse("INT. COPY - DAY {#s001 color=red}\n\nCopied.\n\nINT. CELLAR - DAY {#s003}\n\nDust.\n")
        let edits = SceneEditing.crossFileDuplicates(in: [first, second])
        #expect(edits[0].isEmpty)
        #expect(edits[1].map(\.sceneID) == ["s004"])
        #expect(edits[1].first?.replacement == " {#s004 color=red}")
    }
}

@Suite("Snapshots")
struct SnapshotTests {
    @Test func saveListAndRead() throws {
        let folder = try TempFolder()
        let date = Date(timeIntervalSince1970: 1_795_400_000)
        let snapshot = try ScriptSnapshot.save(name: "Before: the rewrite", files: [(name: "01-act-one.md", text: "INT. A - DAY\n")], in: folder.url, date: date)
        #expect(snapshot.name == "Before- the rewrite")
        #expect(snapshot.date != nil)
        let again = try ScriptSnapshot.save(name: "Before: the rewrite", files: [], in: folder.url, date: date)
        #expect(again.folderName.hasSuffix(" 2"))
        #expect(ScriptSnapshot.all(in: folder.url).count == 2)
        #expect(try snapshot.files().map(\.text) == ["INT. A - DAY\n"])
        #expect(snapshot.url.path.contains("script/.snapshots/"))
    }

    @Test func sideBySideRows() {
        let rows = LineDiff.rows(old: ["a", "b", "c", "d"], new: ["a", "B", "c", "e", "f"])
        #expect(rows.map(\.kind) == [.same, .changed, .same, .changed, .added])
        #expect(rows[1].old == "b" && rows[1].new == "B")
        #expect(LineDiff.rows(old: ["a", "b"], new: ["a"]).map(\.kind) == [.same, .removed])
    }
}
