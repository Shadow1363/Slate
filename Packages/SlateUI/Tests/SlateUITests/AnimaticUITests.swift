import AppKit
import AVFoundation
import Foundation
import Testing
@testable import SlateCore
@testable import SlateExport
@testable import SlateUI

@MainActor
@Suite("Animatic", .serialized)
struct AnimaticUITests {
    static let kitchen = "storyboard/scenes/s014 int-kitchen-night"

    /// A short silent `.caf` to stand in for a recording.
    private func sound(_ folder: URL, _ name: String) throws -> URL {
        let url = folder.appending(path: name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
        buffer.frameLength = 22_050
        try file.write(from: buffer)
        return url
    }

    private func addRoofScene(_ h: SessionHarness) throws {
        let document = try h.store.document(at: "script/script.md")
        document.text += "\nEXT. ROOF - DAWN {#s015}\n\nWind tears at the washing lines.\n"
        h.store.save(document)
        h.session.filesChanged()
    }

    @Test func timelineComesFromTheBoardsAndScript() throws {
        let h = try SessionHarness()
        try addRoofScene(h)
        let model = h.session.storyboard
        let film = model.timeline()
        #expect(film.segments.map(\.sceneID) == ["s014", "s014", "s014", "s015"])
        #expect(film.segments[0].duration == 3)
        #expect(film.segments[3].content == .placeholder("Wind tears at the washing lines."))
        #expect(film.subtitles.contains { $0.character == "OLDER MARA" })
        #expect(model.ref(for: film.segments[1]) == FrameRef(folder: Self.kitchen, file: "02.png"))
        #expect(model.ref(for: film.segments[3]) == nil)
        #expect(model.timeline(.scene("s015")).segments.count == 1)
    }

    @Test func scratchAudioIsCopiedAndNamedInFramesJSON() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        let source = try sound(h.folder, "read-through.caf")
        model.setScratchAudio(source, row: "s014")
        var frames = try FramesFile(text: h.read(Self.kitchen + "/frames.json"))
        #expect(frames.scratchAudio == "scratch.caf")
        #expect(FileManager.default.fileExists(atPath: h.store.rootURL.appending(path: Self.kitchen + "/scratch.caf").path))
        // Scratch audio is never a frame.
        #expect(model.rows[0].frames.map(\.file) == ["01.png", "02.png", "03.png"])
        #expect(model.scratchAudio(model.rows[0]) == "scratch.caf")
        #expect(model.timeline().audio.map(\.path) == [Self.kitchen + "/scratch.caf"])

        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        undo.beginUndoGrouping()
        model.setScratchVolume(0.4, row: "s014")
        undo.endUndoGrouping()
        frames = try FramesFile(text: h.read(Self.kitchen + "/frames.json"))
        #expect(frames.scratchVolume == 0.4)
        undo.undo()
        #expect(try FramesFile(text: h.read(Self.kitchen + "/frames.json")).scratchVolume == nil)

        // Replacing sends the old file to the Trash.
        model.setScratchAudio(try sound(h.folder, "take-2.caf"), row: "s014")
        #expect(model.scratchAudio(model.rows[0]) == "scratch.caf")
        model.removeScratchAudio(row: "s014")
        frames = try FramesFile(text: h.read(Self.kitchen + "/frames.json"))
        #expect(frames.scratchAudio == nil)
        #expect(!FileManager.default.fileExists(atPath: h.store.rootURL.appending(path: Self.kitchen + "/scratch.caf").path))
    }

    @Test func scratchAudioOnAnUnboardedSceneMakesItsFolder() throws {
        let h = try SessionHarness()
        try addRoofScene(h)
        let model = h.session.storyboard
        model.setScratchAudio(try sound(h.folder, "wind.caf"), row: "s015")
        let folder = "storyboard/scenes/s015 ext-roof-dawn"
        #expect(try FramesFile(text: h.read(folder + "/frames.json")).scratchAudio == "scratch.caf")
        let roof = try #require(model.rows.first { $0.id == "s015" })
        #expect(roof.frames.isEmpty)
        #expect(model.timeline(.scene("s015")).audio.first?.path == folder + "/scratch.caf")
    }

    @Test func settingsScoreAndPushIn() throws {
        let h = try SessionHarness()
        let model = h.session.storyboard
        #expect(model.settings.score == nil)
        model.setScore(try sound(h.folder, "theme.caf"))
        #expect(model.settings.score == "score.caf")
        #expect(try h.read("storyboard/storyboard.json").contains("\"score\": \"score.caf\""))
        #expect(model.timeline().audio.map(\.kind) == [.score])

        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        undo.beginUndoGrouping()
        model.updateSettings("Change Push-In") { $0.pushIn = true }
        undo.endUndoGrouping()
        #expect(model.settings.pushIn)
        #expect(model.timeline().segments.map(\.motion) == [.none, .pushIn, .pushIn]) // 01 is "static"
        undo.undo()
        #expect(!model.settings.pushIn)
        #expect(model.settings.score == "score.caf")

        model.updateSettings(nil) { $0.guide = .flat }
        #expect(model.defaultGuide == .flat)
        #expect(model.timeline().guide == .flat)

        model.removeScore()
        #expect(model.settings.score == nil)
        #expect(!FileManager.default.fileExists(atPath: h.store.rootURL.appending(path: "storyboard/score.caf").path))
    }

    @Test func playerBuildsRangesAndSteps() async throws {
        let h = try SessionHarness()
        try addRoofScene(h)
        let player = AnimaticPlayerModel(storyboard: h.session.storyboard, root: h.store.rootURL)
        defer { player.stop() }
        #expect(player.rangeTitle == "Whole Film")
        player.play(.film, autoplay: false)
        try await waitUntil { !player.timeline.segments.isEmpty && !player.isBuilding }
        #expect(player.timeline.segments.count == 4)
        #expect(player.errorMessage == nil)
        #expect(player.player.currentItem != nil)

        player.seek(to: 4)
        #expect(player.currentSegment?.file == "02.png")
        player.stepFrame(1)
        #expect(player.currentSegment?.file == "03.png")
        player.stepScene(1)
        #expect(player.currentSegment?.sceneID == "s015")
        player.stepScene(-1)
        #expect(player.currentSegment?.sceneID == "s014")

        var selected: FrameRef?
        player.onSelect = { selected = $0 }
        player.seek(to: 0.5)
        player.selectCurrentFrame()
        #expect(selected == FrameRef(folder: Self.kitchen, file: "01.png"))

        player.setFrom("s015")
        #expect(player.rangeTitle == "Scenes 2–2")
        player.setTo("s014")
        #expect(player.rangeTitle == "Scenes 1–2")
        player.play(.fromFrame(scene: "s014", file: "03.png"), autoplay: false)
        #expect(player.rangeTitle == "From Scene 1")
        try await waitUntil { player.timeline.segments.first?.file == "03.png" && !player.isBuilding }
        #expect(player.timeline.segments.count == 2)
        #expect(player.rangeEnds.to == "s015")
    }

    @Test func overlaysAreRemembered() {
        let saved = AnimaticPlayerModel.savedOverlays
        defer { AnimaticPlayerModel.save(saved) }
        AnimaticPlayerModel.save(AnimaticOverlays(heading: false, caption: true, subtitles: false))
        #expect(AnimaticPlayerModel.savedOverlays == AnimaticOverlays(heading: false, caption: true, subtitles: false))
        #expect(AnimaticPlayerModel.time(75.4) == "1:15")
        #expect(AnimaticPlayerView.videoRect(in: CGSize(width: 1000, height: 1000)) == CGRect(x: 0, y: 218.75, width: 1000, height: 562.5))
    }

    @Test func exportRouting() async throws {
        #expect(ExportFormat.allCases.filter { !$0.isScript } == [.animatic, .boards])
        let h = try SessionHarness()
        h.session.exportBoards(.six)
        let job = try #require(h.session.exportJob)
        await job.task?.value
        #expect(h.session.exportJob == nil)
        let exports = try FileManager.default.contentsOfDirectory(atPath: h.store.rootURL.appending(path: "exports").path)
        #expect(exports.contains { $0.contains("– Boards –") && $0.hasSuffix(".pdf") })
        #expect(UserDefaults.standard.integer(forKey: "boards.perPage") == 6)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out")
    }
}
