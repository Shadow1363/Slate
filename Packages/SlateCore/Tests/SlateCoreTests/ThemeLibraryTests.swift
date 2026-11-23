import Foundation
import Testing
@testable import SlateCore

@MainActor
@Suite("Theme library")
struct ThemeLibraryTests {
    @Test func duplicateEditResetDeleteImportExport() throws {
        let folder = try TempFolder()
        let themes = folder.url.appending(path: "Themes")
        let engine = ThemeEngine(userThemesDirectory: themes)

        let copy = try engine.duplicate(named: "Dark")
        #expect(copy == "Dark Copy")
        let file = themes.appending(path: "Dark Copy.slatetheme")
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\n  \"base\" : \"Dark\",\n  \"name\" : \"Dark Copy\"\n}\n")
        #expect(try engine.resolve(named: copy) == ThemeEngine.builtInDark.renamed(copy))

        // Tokens resolve through the base; only set ones count as overridden.
        let tokens = try engine.tokens(of: copy)
        let heading = try #require(tokens.first { $0.id == "script.sceneHeading.color" })
        #expect(heading.kind == .color)
        #expect(!heading.overridden)
        #expect(heading.title == "Scene Heading › Color")
        #expect(tokens.first?.group == "chrome")
        #expect(tokens.contains { $0.kind == .font } && tokens.contains { $0.kind == .number } && tokens.contains { $0.kind == .toggle })

        try engine.set(.string("#F2C46D"), at: ["script", "sceneHeading", "color"], in: copy)
        #expect(try engine.resolve(named: copy).script.sceneHeading.color.hex == "#F2C46D")
        #expect(try engine.tokens(of: copy).first { $0.id == "script.sceneHeading.color" }?.overridden == true)
        // A bad value is refused and the file stays readable.
        #expect(throws: ThemeError.self) { try engine.set(.string("#12"), at: ["editor", "background"], in: copy) }
        #expect(throws: ThemeError.self) { try engine.set(.string("#000000"), at: ["editor", "background"], in: "Dark") }
        // Reset drops the override and the empty groups.
        try engine.set(nil, at: ["script", "sceneHeading", "color"], in: copy)
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("script"))

        let shared = folder.url.appending(path: "shared.slatetheme")
        try engine.export(named: copy, to: shared)
        let imported = try engine.importTheme(from: shared)
        #expect(imported == "Dark Copy 2")
        #expect(engine.themes.map(\.name).contains("Dark Copy 2"))

        try engine.delete(named: copy)
        #expect(engine.source(named: copy) == nil)
        #expect(throws: ThemeError.self) { try engine.delete(named: "Light") }
    }
}

extension ResolvedTheme {
    func renamed(_ name: String) -> ResolvedTheme {
        var copy = self
        copy.name = name
        return copy
    }
}

@Suite("Text size")
struct TextScaleTests {
    @Test func scalingTouchesSizesOnly() {
        let base = ThemeEngine.builtInLight
        let big = base.scaled(by: 1.5)
        #expect(big.script.action.size == base.script.action.size * 1.5)
        #expect(big.markdown.h1Size == base.markdown.h1Size * 1.5)
        #expect(big.script.action.color == base.script.action.color)
        #expect(base.scaled(by: 1) == base)
    }
}
