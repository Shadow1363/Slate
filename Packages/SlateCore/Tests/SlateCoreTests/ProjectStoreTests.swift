import Foundation
import Testing
@testable import SlateCore

@MainActor
@Suite("ProjectStore")
struct ProjectStoreTests {
    @Test func opensTheSampleProject() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)

        #expect(store.manifest.name == "The Brass Key")
        #expect(store.files[.script]?.map(\.relativePath) == [
            "script/margin/notes.md", "script/margin/todos.md", "script/script.md", "script/title-page.md",
        ])
        #expect(store.files[.universe]?.map(\.pathInArea) == [
            "canvases/act-two.canvas", "canvases/images/station-sketch.png",
            "characters/mara-voss.md", "characters/thomas-wiley-cade.md", "draft.md", "items/the-brass-key.md",
            "locations/the-station.md", "maps/city.map.json", "maps/city.png", "rules/powers.md", "rules/time-travel.md",
            "timelines/main.timeline.json",
        ])
        #expect(store.files[.dictionary]?.map(\.name) == ["words.md"])
        // Hidden files (.gitkeep) are not listed.
        #expect(store.files[.storyboard]?.map(\.name) == ["storyboard.json"])
    }

    @Test func refusesAFolderWithoutManifest() throws {
        let folder = try TempFolder()
        #expect(throws: ProjectStoreError.notAProject(folder.url.path)) {
            try ProjectStore(rootURL: folder.url)
        }
    }

    @Test func refusesPathsOutsideTheProject() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        #expect(throws: ProjectStoreError.invalidPath("../escape.md")) { try store.url(for: "../escape.md") }
    }

    @Test func cleanDocumentReloadsOutsideEdit() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let doc = try store.document(at: "universe/draft.md")

        try Data("Changed in VS Code\n".utf8).write(to: root.appending(path: "universe/draft.md"))
        store.handleExternalChanges(["universe/draft.md"])

        #expect(doc.text == "Changed in VS Code\n")
        #expect(!doc.isDirty)
        #expect(doc.diskState == .inSync)
    }

    @Test func dirtyDocumentGetsAConflictNotAnOverwrite() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let doc = try store.document(at: "universe/draft.md")
        doc.text = "my unsaved edit"

        try Data("theirs".utf8).write(to: root.appending(path: "universe/draft.md"))
        store.handleExternalChanges(["universe/draft.md"])

        #expect(doc.text == "my unsaved edit")
        #expect(doc.diskState == .changedOnDisk("theirs"))

        // Saving while in conflict must not clobber their version.
        store.save(doc)
        #expect(try String(contentsOf: root.appending(path: "universe/draft.md"), encoding: .utf8) == "theirs")
    }

    @Test func keepMineWritesTheBuffer() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let doc = try store.document(at: "universe/draft.md")
        doc.text = "mine"
        try Data("theirs".utf8).write(to: root.appending(path: "universe/draft.md"))
        store.handleExternalChanges()

        store.keepMine(doc)

        #expect(try String(contentsOf: root.appending(path: "universe/draft.md"), encoding: .utf8) == "mine")
        #expect(doc.diskState == .inSync)
        #expect(!doc.isDirty)
    }

    @Test func loadTheirsTakesTheDiskVersion() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let doc = try store.document(at: "universe/draft.md")
        doc.text = "mine"
        try Data("theirs".utf8).write(to: root.appending(path: "universe/draft.md"))
        store.handleExternalChanges()

        store.loadTheirs(doc)

        #expect(doc.text == "theirs")
        #expect(doc.diskState == .inSync)
        #expect(!doc.isDirty)
    }

    @Test func saveCatchesAnUnreportedOutsideEdit() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let doc = try store.document(at: "universe/draft.md")
        doc.text = "mine"
        // The watcher hasn't told the store yet.
        try Data("theirs".utf8).write(to: root.appending(path: "universe/draft.md"))

        store.save(doc)

        #expect(doc.diskState == .changedOnDisk("theirs"))
        #expect(try String(contentsOf: root.appending(path: "universe/draft.md"), encoding: .utf8) == "theirs")
    }

    @Test func ownSaveIsNotAConflict() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let doc = try store.document(at: "universe/draft.md")
        doc.text = "saved by Slate"
        store.save(doc)
        store.handleExternalChanges(["universe/draft.md"])

        #expect(doc.diskState == .inSync)
        #expect(!doc.isDirty)
        #expect(try String(contentsOf: root.appending(path: "universe/draft.md"), encoding: .utf8) == "saved by Slate")
    }

    @Test func deletionKeepsTheBuffer() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let doc = try store.document(at: "universe/draft.md")

        try FileManager.default.removeItem(at: root.appending(path: "universe/draft.md"))
        store.handleExternalChanges(["universe/draft.md"])

        #expect(doc.diskState == .deletedOnDisk)
        #expect(doc.text.hasPrefix("# The Brass Key"))
        #expect(store.files[.universe]?.contains { $0.name == "draft.md" } == false)

        store.keepMine(doc)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "universe/draft.md").path))
        #expect(doc.diskState == .inSync)
    }

    @Test func outsideManifestEditUpdatesTheStore() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let url = root.appending(path: "project.json")

        var manifest = store.manifest
        manifest.name = "Renamed by hand"
        try manifest.encoded().write(to: url)
        store.handleExternalChanges(["project.json"])
        #expect(store.manifest.name == "Renamed by hand")

        try Data("{ broken".utf8).write(to: url)
        store.handleExternalChanges(["project.json"])
        #expect(store.manifest.name == "Renamed by hand")
        #expect(store.manifestError != nil)
    }

    @Test func autosaveWritesAfterIdle() async throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: .milliseconds(100))
        let doc = try store.document(at: "universe/draft.md")
        doc.text = "autosaved"

        let saved = await waitUntil { !doc.isDirty }
        #expect(saved)
        #expect(try String(contentsOf: root.appending(path: "universe/draft.md"), encoding: .utf8) == "autosaved")
    }

    /// The milestone's "done when", end to end: edit a file outside the app
    /// and watch the open document reload.
    @Test func watcherReloadsAnOpenDocument() async throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        store.startWatching()
        defer { store.close() }
        let doc = try store.document(at: "script/title-page.md")
        try await Task.sleep(for: .milliseconds(300))

        try Data("Title: Edited in TextEdit\n".utf8).write(to: root.appending(path: "script/title-page.md"))
        try Data("new note".utf8).write(to: root.appending(path: "universe/new-note.md"))

        let reloaded = await waitUntil { doc.text == "Title: Edited in TextEdit\n" }
        #expect(reloaded)
        let listed = await waitUntil { store.files[.universe]?.contains { $0.name == "new-note.md" } == true }
        #expect(listed)
    }
}

@MainActor
@Suite("ProjectStore manifest")
struct ProjectStoreManifestTests {
    @Test func updateManifestWritesAndKeepsUnknownKeys() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        try store.updateManifest { PublishSettings(autoContd: false).apply(to: &$0) }
        let reread = try ProjectManifest.decode(Data(contentsOf: root.appending(path: "project.json")))
        #expect(PublishSettings(manifest: reread).autoContd == false)
        #expect(reread.extra["studio"] != nil)
        // The watcher sees our own write as no change.
        store.handleExternalChanges(["project.json"])
        #expect(store.manifestError == nil)
        #expect(PublishSettings(manifest: store.manifest).autoContd == false)
    }
}
