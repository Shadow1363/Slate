import Foundation
import Testing
@testable import SlateCore

@Suite("New Project")
struct ProjectCreatorTests {
    @Test(arguments: ProjectTemplate.allCases.filter { $0 != .showcase })
    func everyTemplateCreatesAValidProject(_ template: ProjectTemplate) throws {
        let folder = try TempFolder()
        let root = try ProjectCreator.create(title: "My Film", template: template, in: folder.url)

        #expect(root.lastPathComponent == "My Film")
        let manifest = try ProjectManifest.decode(Data(contentsOf: root.appending(path: "project.json")))
        #expect(manifest.name == "My Film")
        #expect(manifest.schemaVersion == ProjectManifest.currentSchemaVersion)

        var isDirectory: ObjCBool = false
        for path in template.folders {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: path).path, isDirectory: &isDirectory) && isDirectory.boolValue, "missing \(path)")
        }
        for path in ["universe/draft.md", "script/title-page.md", "script/margin/todos.md", "script/margin/notes.md",
                     "storyboard/storyboard.json", "dictionary/words.md"] {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: path).path), "missing \(path)")
        }
        // The store can open what the creator made.
        _ = try SlateJSON.decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "storyboard/storyboard.json")))
    }

    @Test func templatesDifferInStarterFiles() throws {
        let folder = try TempFolder()
        let feature = try ProjectCreator.create(title: "F", template: .feature, in: folder.url)
        let short = try ProjectCreator.create(title: "S", template: .short, in: folder.url)
        let pilot = try ProjectCreator.create(title: "P", template: .tvPilot, in: folder.url)
        let blank = try ProjectCreator.create(title: "B", template: .blank, in: folder.url)

        func scriptFiles(_ root: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "script").path)
                .filter { $0.hasSuffix(".md") && $0 != "title-page.md" }.sorted()
        }
        #expect(try scriptFiles(feature) == ["01-act-one.md", "02-act-two.md", "03-act-three.md"])
        #expect(try scriptFiles(short) == ["script.md"])
        #expect(try scriptFiles(pilot).count == 5)
        #expect(try scriptFiles(blank) == ["script.md"])
        #expect(!FileManager.default.fileExists(atPath: blank.appending(path: "universe/characters").path))
        #expect(FileManager.default.fileExists(atPath: feature.appending(path: "universe/characters").path))

        let titlePage = try String(contentsOf: feature.appending(path: "script/title-page.md"), encoding: .utf8)
        #expect(titlePage.hasPrefix("Title: F\nCredit: written by\n"))
    }

    @Test func refusesANonEmptyFolder() throws {
        let folder = try TempFolder()
        try folder.write("keep me", to: "Taken/notes.txt")
        #expect(throws: ProjectCreationError.folderNotEmpty(folder.file("Taken").path)) {
            try ProjectCreator.create(title: "Taken", template: .short, in: folder.url)
        }
        #expect(try folder.read("Taken/notes.txt") == "keep me")
    }

    @Test func refusesAnEmptyTitle() throws {
        let folder = try TempFolder()
        #expect(throws: ProjectCreationError.emptyTitle) {
            try ProjectCreator.create(title: "   ", template: .short, in: folder.url)
        }
    }

    @Test func folderNamesAreFinderSafe() {
        #expect(ProjectCreator.folderName(for: "Act 1/2: The Key") == "Act 1-2- The Key")
        #expect(ProjectCreator.folderName(for: ".hidden") == "hidden")
        #expect(ProjectCreator.folderName(for: "  ") == "Untitled")
    }

    @Test func summaryReadsNameAndNewestEdit() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let summary = try #require(ProjectSummary.load(at: root))
        #expect(summary.name == "The Brass Key")
        #expect(summary.lastEdited != nil)
    }

    @Test func scannerFindsProjectsOneLevelDown() throws {
        let folder = try TempFolder()
        try ProjectCreator.create(title: "One", template: .blank, in: folder.url)
        try ProjectCreator.create(title: "Two", template: .blank, in: folder.url)
        try folder.write("x", to: "Not A Project/readme.txt")
        #expect(ProjectScanner.projects(in: folder.url).map(\.lastPathComponent) == ["One", "Two"])
    }

    @MainActor
    @Test func showcaseCopiesTheSampleUnderANewName() throws {
        let folder = try TempFolder()
        let showcase = Fixtures.root.deletingLastPathComponent().appending(path: "Showcase/Tidewater", directoryHint: .isDirectory)
        let original = try ProjectManifest.decode(Data(contentsOf: showcase.appending(path: "project.json")))
        let root = try ProjectCreator.create(title: "My Tidewater", template: .showcase, in: folder.url, sample: showcase)
        let manifest = try ProjectManifest.decode(Data(contentsOf: root.appending(path: "project.json")))
        #expect(manifest.name == "My Tidewater")
        #expect(manifest.id != original.id)
        for path in ["script/01-act-one.md", "universe/maps/saltmarrow.png", "storyboard/scenes/s003 int-the-lighthouse-lamp-room-night/02.mov",
                     "SHOWCASE.md", ".slate"] {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: path).path), "missing \(path)")
        }
        // It opens like any project.
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        #expect(store.manifest.name == "My Tidewater")
        // Without the sample (as in a test runner), it says so.
        #expect(throws: ProjectCreationError.sampleMissing) {
            try ProjectCreator.create(title: "X", template: .showcase, in: folder.url, sample: nil)
        }
    }
}
