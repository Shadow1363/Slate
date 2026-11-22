import Foundation
import Testing
@testable import SlateCore

@Suite("project.json")
struct ManifestTests {
    @Test func fixtureRoundTripsByteIdentical() throws {
        let data = try Data(contentsOf: Fixtures.sampleProject.appending(path: "project.json"))
        let manifest = try ProjectManifest.decode(data)
        #expect(manifest.name == "The Brass Key")
        #expect(manifest.id == "p-fixture-0001")
        #expect(manifest.pageSize == .letter)
        #expect(try manifest.encoded() == data)
    }

    @Test func unknownKeysSurviveAnEdit() throws {
        let data = try Data(contentsOf: Fixtures.sampleProject.appending(path: "project.json"))
        var manifest = try ProjectManifest.decode(data)
        manifest.name = "Renamed"
        let reread = try ProjectManifest.decode(try manifest.encoded())
        #expect(reread.name == "Renamed")
        #expect(reread.extra["studio"]?["note"]?.stringValue == "Unknown keys like this one must survive a save.")
        #expect(reread.settings["reminders"]?.stringValue == "lastProject")
    }

    @Test func newManifestRoundTrips() throws {
        let manifest = ProjectManifest(name: "My Film", theme: "Night Draft")
        let data = try manifest.encoded()
        #expect(try ProjectManifest.decode(data) == manifest)
        #expect(try ProjectManifest.decode(data).encoded() == data)
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("}\n"))
    }

    @Test func readableErrors() throws {
        #expect(throws: ManifestError.missingField("name")) {
            try ProjectManifest.decode(Data(#"{"id":"x","schemaVersion":1}"#.utf8))
        }
        #expect(throws: ManifestError.invalidField("pageSize", "expected \"letter\" or \"a4\"")) {
            try ProjectManifest.decode(Data(#"{"name":"A","id":"x","schemaVersion":1,"pageSize":"legal"}"#.utf8))
        }
        #expect(throws: ManifestError.notAnObject) {
            try ProjectManifest.decode(Data("[]".utf8))
        }
    }

    @Test func a4IsCaseInsensitive() throws {
        let manifest = try ProjectManifest.decode(Data(#"{"name":"A","id":"x","schemaVersion":1,"pageSize":"A4"}"#.utf8))
        #expect(manifest.pageSize == .a4)
    }
}

@Suite("Migration")
struct MigrationTests {
    @Test func newerSchemaIsRefused() throws {
        let folder = try TempFolder()
        let manifest = ProjectManifest(name: "Future", schemaVersion: 99)
        #expect(throws: MigrationError.newerSchema(found: 99, supported: ProjectManifest.currentSchemaVersion)) {
            try ProjectMigrator.migrateIfNeeded(manifest, originalData: try manifest.encoded(), projectRoot: folder.url)
        }
    }

    @Test func olderSchemaIsBackedUpThenBumped() throws {
        let folder = try TempFolder()
        let old = ProjectManifest(name: "Old", schemaVersion: 0)
        let original = try old.encoded()
        try original.write(to: folder.file("project.json"))

        let migrated = try ProjectMigrator.migrateIfNeeded(old, originalData: original, projectRoot: folder.url)

        #expect(migrated.schemaVersion == ProjectManifest.currentSchemaVersion)
        let onDisk = try ProjectManifest.decode(Data(contentsOf: folder.file("project.json")))
        #expect(onDisk.schemaVersion == ProjectManifest.currentSchemaVersion)
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.file(".slate/backups").path)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: folder.file(".slate/backups/\(backups[0])")) == original)
    }

    @Test func hashHeadingsBecomeFountainHeadings() {
        let old = """
        # INT. KITCHEN - NIGHT {#s014}

        Rain.
        # THE VAULT {#s015}

        /*
        # not a heading, in the boneyard
        */

        ## EXT. ROOF - DAY {#s016}
        """
        #expect(ProjectMigrator.fountainHeadings(from: old) == """
        INT. KITCHEN - NIGHT {#s014}

        Rain.
        .THE VAULT {#s015}

        /*
        # not a heading, in the boneyard
        */

        EXT. ROOF - DAY {#s016}
        """)
    }

    @Test func schemaOneScriptsAreMigratedWithBackups() throws {
        let folder = try TempFolder()
        let old = ProjectManifest(name: "Old", schemaVersion: 1)
        let original = try old.encoded()
        try original.write(to: folder.file("project.json"))
        try folder.write("# INT. KITCHEN - NIGHT {#s014}\n\nRain.\n", to: "script/script.md")
        try folder.write("Title: Old\n", to: "script/title-page.md")
        try folder.write("Already fine.\n", to: "script/02-act-two.md")

        _ = try ProjectMigrator.migrateIfNeeded(old, originalData: original, projectRoot: folder.url)

        #expect(try folder.read("script/script.md") == "INT. KITCHEN - NIGHT {#s014}\n\nRain.\n")
        #expect(try folder.read("script/title-page.md") == "Title: Old\n")
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.file(".slate/backups").path)
        let scriptBackup = try #require(backups.first { $0.hasPrefix("script-v1-") })
        #expect(try folder.read(".slate/backups/\(scriptBackup)/script.md") == "# INT. KITCHEN - NIGHT {#s014}\n\nRain.\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.file(".slate/backups/\(scriptBackup)").path) == ["script.md"])
    }

    @Test func currentSchemaIsLeftAlone() throws {
        let folder = try TempFolder()
        let manifest = ProjectManifest(name: "Now")
        let result = try ProjectMigrator.migrateIfNeeded(manifest, originalData: try manifest.encoded(), projectRoot: folder.url)
        #expect(result == manifest)
        #expect(!FileManager.default.fileExists(atPath: folder.file(".slate").path))
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func deepMergeOverridesLeavesAndKeepsSiblings() {
        let base = JSONValue.object([
            "editor": .object(["background": .string("#000000"), "text": .string("#FFFFFF")]),
            "lanes": .array([.string("#111111"), .string("#222222")]),
        ])
        let top = JSONValue.object([
            "editor": .object(["text": .string("#EEEEEE")]),
            "lanes": .array([.string("#333333")]),
        ])
        let merged = base.merging(top)
        #expect(merged["editor"]?["background"]?.stringValue == "#000000")
        #expect(merged["editor"]?["text"]?.stringValue == "#EEEEEE")
        #expect(merged["lanes"] == .array([.string("#333333")]))
    }

    @Test func numbersKeepTheirShape() throws {
        let data = Data(#"{"a":1,"b":1.5,"c":true,"d":null}"#.utf8)
        let value = try SlateJSON.decode(JSONValue.self, from: data)
        #expect(value["a"] == .int(1))
        #expect(value["b"] == .double(1.5))
        #expect(value["c"] == .bool(true))
        #expect(value["d"] == .null)
    }
}
