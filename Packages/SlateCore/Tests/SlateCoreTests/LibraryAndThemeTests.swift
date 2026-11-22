import Foundation
import Testing
@testable import SlateCore

@MainActor
@Suite("ProjectLibrary")
struct ProjectLibraryTests {
    @Test func addPersistsAndRemoveKeepsFiles() throws {
        let support = try TempFolder()
        let projects = try TempFolder()
        let root = try ProjectCreator.create(title: "Kept", template: .blank, in: projects.url)

        let library = ProjectLibrary(directory: support.url, defaultWatchedFolder: projects.url)
        let entry = try library.add(root)
        #expect(try library.add(root).id == entry.id, "adding twice returns the same entry")

        let reopened = ProjectLibrary(directory: support.url, defaultWatchedFolder: projects.url)
        #expect(reopened.entries.map(\.id) == [entry.id])

        reopened.remove(entry.id)
        #expect(reopened.entries.isEmpty)
        #expect(ProjectScanner.isProject(root))
    }

    @Test func refusesANonProjectFolder() throws {
        let support = try TempFolder()
        let plain = try TempFolder()
        let library = ProjectLibrary(directory: support.url, defaultWatchedFolder: plain.url)
        #expect(throws: LibraryError.notAProject(plain.url.path)) { try library.add(plain.url) }
    }

    @Test func bookmarkFollowsAMove() throws {
        let support = try TempFolder()
        let projects = try TempFolder()
        let root = try ProjectCreator.create(title: "Wanderer", template: .blank, in: projects.url)
        let library = ProjectLibrary(directory: support.url, defaultWatchedFolder: projects.url)
        let entry = try library.add(root)

        let moved = projects.url.appending(path: "Moved/Wanderer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root, to: moved)

        guard case .found(let url) = library.resolve(entry.id) else {
            Issue.record("moved project was not found")
            return
        }
        #expect(canonicalPath(url) == canonicalPath(moved))
        #expect(canonicalPath(library.entries[0].lastKnownURL) == canonicalPath(moved))
    }

    @Test func deletedProjectIsMissingAndCanBeRelocated() throws {
        let support = try TempFolder()
        let projects = try TempFolder()
        let root = try ProjectCreator.create(title: "Gone", template: .blank, in: projects.url)
        let library = ProjectLibrary(directory: support.url, defaultWatchedFolder: projects.url)
        let entry = try library.add(root)

        let copy = projects.url.appending(path: "Restored", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: root, to: copy)
        try FileManager.default.removeItem(at: root)

        #expect(library.resolve(entry.id) == .missing)
        #expect(library.missing.contains(entry.id))

        try library.relocate(entry.id, to: copy)
        guard case .found(let url) = library.resolve(entry.id) else {
            Issue.record("relocated project was not found")
            return
        }
        #expect(canonicalPath(url) == canonicalPath(copy))
        #expect(!library.missing.contains(entry.id))
    }

    @Test func watchedFolderScanAddsProjectsButNotRemovedOnes() throws {
        let support = try TempFolder()
        let projects = try TempFolder()
        try ProjectCreator.create(title: "A", template: .blank, in: projects.url)
        try ProjectCreator.create(title: "B", template: .blank, in: projects.url)
        let library = ProjectLibrary(directory: support.url, defaultWatchedFolder: projects.url)

        library.scanWatchedFolders()
        #expect(library.entries.count == 2)

        library.remove(library.entries[0].id)
        library.scanWatchedFolders()
        #expect(library.entries.count == 1)
    }

    @Test func recentAndPinned() throws {
        let support = try TempFolder()
        let projects = try TempFolder()
        let library = ProjectLibrary(directory: support.url, defaultWatchedFolder: projects.url)
        let a = try library.add(try ProjectCreator.create(title: "A", template: .blank, in: projects.url))
        let b = try library.add(try ProjectCreator.create(title: "B", template: .blank, in: projects.url))

        library.markOpened(a.id, at: Date(timeIntervalSince1970: 100))
        library.markOpened(b.id, at: Date(timeIntervalSince1970: 200))
        library.setPinned(true, for: a.id)

        #expect(library.recent.map(\.id) == [b.id, a.id])
        #expect(library.pinned.map(\.id) == [a.id])
    }
}

@MainActor
@Suite("ThemeEngine")
struct ThemeEngineTests {
    @Test func builtInsResolveCompletely() {
        #expect(ThemeEngine.builtInLight.name == "Light")
        #expect(ThemeEngine.builtInLight.appearance == .light)
        #expect(ThemeEngine.builtInDark.appearance == .dark)
        #expect(ThemeEngine.builtInDark.script.sceneHeading.uppercase)
    }

    @Test func partialThemeFallsBackToBase() throws {
        let folder = try TempFolder()
        try folder.write("""
        {
          "name": "Night Draft",
          "base": "dark",
          "editor": { "background": "#14161A", "text": "#E6E2D8", "lineSpacing": 1.4 },
          "script": {
            "sceneHeading": { "font": "Courier Prime", "size": 13, "weight": "bold", "color": "#F2C46D" },
            "character": { "color": "#9CC3FF" }
          }
        }
        """, to: "night.slatetheme")
        let engine = ThemeEngine(userThemesDirectory: folder.url)
        #expect(engine.loadErrors.isEmpty)

        let theme = try engine.resolve(named: "Night Draft")
        #expect(theme.editor.background.hex == "#14161A")
        #expect(theme.editor.lineSpacing == 1.4)
        #expect(theme.script.character.color.hex == "#9CC3FF")
        // Left out, so inherited from Dark.
        #expect(theme.script.character.font == ThemeEngine.builtInDark.script.character.font)
        #expect(theme.editor.caret == ThemeEngine.builtInDark.editor.caret)
        #expect(theme.appearance == .dark)
    }

    @Test func badHexIsReportedWithItsPath() throws {
        let folder = try TempFolder()
        try folder.write(##"{ "name": "Bad", "base": "light", "editor": { "background": "#12" } }"##, to: "bad.slatetheme")
        let engine = ThemeEngine(userThemesDirectory: folder.url)
        do {
            _ = try engine.resolve(named: "Bad")
            Issue.record("expected an error")
        } catch let ThemeError.invalid(name, reason) {
            #expect(name == "Bad")
            #expect(reason.contains("editor.background"))
            #expect(reason.contains("#12"))
        }
    }

    @Test func baseCyclesAndMissingThemesFail() throws {
        let folder = try TempFolder()
        try folder.write(#"{ "name": "Ping", "base": "Pong" }"#, to: "ping.slatetheme")
        try folder.write(#"{ "name": "Pong", "base": "Ping" }"#, to: "pong.slatetheme")
        let engine = ThemeEngine(userThemesDirectory: folder.url)
        #expect(throws: ThemeError.baseCycle("Ping")) { try engine.resolve(named: "Ping") }
        #expect(throws: ThemeError.notFound("Nope")) { try engine.resolve(named: "Nope") }
    }

    @Test func userThemeCannotShadowABuiltIn() throws {
        let folder = try TempFolder()
        try folder.write(#"{ "name": "Dark", "base": "light" }"#, to: "dark.slatetheme")
        let engine = ThemeEngine(userThemesDirectory: folder.url)
        #expect(engine.loadErrors.count == 1)
        #expect(try engine.resolve(named: "Dark") == ThemeEngine.builtInDark)
    }

    @Test func appearanceAndProjectOverride() throws {
        let folder = try TempFolder()
        try folder.write(##"{ "name": "Paper", "base": "light", "editor": { "page": "#FFFDF5" } }"##, to: "paper.slatetheme")
        let engine = ThemeEngine(userThemesDirectory: folder.url)

        #expect(engine.theme(isDark: true, settings: .init(appearance: .system)).name == "Dark")
        #expect(engine.theme(isDark: true, settings: .init(appearance: .light)).name == "Light")
        #expect(engine.theme(isDark: false, settings: .init(appearance: .system, lightTheme: "Paper")).name == "Paper")
        #expect(engine.theme(isDark: true, settings: .init(), projectOverride: "Paper").name == "Paper")
        // An unknown theme name falls back to the built-in instead of failing.
        #expect(engine.theme(isDark: false, settings: .init(lightTheme: "Missing")).name == "Light")
    }

    @Test func hexParsing() {
        #expect(HexColor(hex: "#FFF")?.red == 1)
        #expect(HexColor(hex: "#00000080")?.alpha == Double(0x80) / 255)
        #expect(HexColor(hex: "123456") == nil)
        #expect(HexColor(hex: "#GGGGGG") == nil)
    }
}
