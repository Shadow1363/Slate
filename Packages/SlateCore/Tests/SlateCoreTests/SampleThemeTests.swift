import Foundation
import Testing
@testable import SlateCore

@Suite("Sample themes")
struct SampleThemeTests {
    @Test func everyBuiltInResolves() throws {
        let names = ThemeEngine.builtInSources.map(\.name)
        #expect(names == ["Light", "Dark", "Manuscript", "Midnight"])
        for name in names {
            _ = try ThemeEngine.resolve(named: name, in: ThemeEngine.builtInSources)
        }
    }

    @Test func manuscriptIsCourierOnPaper() throws {
        let theme = try ThemeEngine.resolve(named: "Manuscript", in: ThemeEngine.builtInSources)
        #expect(theme.appearance == .light)
        #expect(theme.markdown.font == "Courier Prime")
        #expect(theme.editor.font == "Courier Prime")
        #expect(theme.editor.background.hex == "#F3EAD6")
        // Only the colour is overridden; the rest comes from Light.
        #expect(theme.script.sceneHeading.color.hex == "#1F1A15")
        #expect(theme.script.sceneHeading.uppercase)
        #expect(theme.script.sceneHeading.weight == ThemeEngine.builtInLight.script.sceneHeading.weight)
    }

    @Test func midnightIsDarkerThanDark() throws {
        let theme = try ThemeEngine.resolve(named: "Midnight", in: ThemeEngine.builtInSources)
        #expect(theme.appearance == .dark)
        #expect(theme.editor.background.hex == "#0B0C0F")
        #expect(theme.markdown.font == ThemeEngine.builtInDark.markdown.font)
        #expect(theme.script.dialogue.font == "Courier Prime")
    }
}
