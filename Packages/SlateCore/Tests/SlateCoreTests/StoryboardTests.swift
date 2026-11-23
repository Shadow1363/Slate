import Foundation
import Testing
@testable import SlateCore

@Suite("Storyboard")
struct StoryboardTests {
    static let script = """
    INT. KITCHEN - NIGHT {#s014}

    Rain hammers the window.

    MARA
    (quietly)
    I haven't opened it yet.

    She sets the key down.

    OLDER MARA (O.S.)
    You already have.

    EXT. ROOF - DAWN {#s015}

    Wind.
    """

    // MARK: frames.json

    @Test func framesRoundTripAndKeepUnknownKeys() throws {
        let text = """
        {
          "scene": "s014",
          "frames": [
            {"file": "01.png", "duration": 3, "shot": "WS", "move": "static", "caption": "Rain on the window", "scriptRange": "action-1"},
            {"file": "02.mov", "in": 1.2, "out": 4.8, "shot": "CU", "caption": "The key", "audio": true, "rating": 5}
          ],
          "notes": "kept"
        }

        """
        let file = try FramesFile(text: text)
        #expect(try FramesFile(text: file.text) == file)
        #expect(file.scene == "s014")
        #expect(file.frames[0].duration == 3)
        #expect(file.frames[0].isClip == false)
        #expect(file.frames[1].isClip)
        #expect(file.frames[1].inPoint == 1.2)
        #expect(file.frames[1].audio)
        #expect(ShotSize(reading: file.frames[1].shot!) == .cu)
        var edited = file
        edited.frames[0].caption = "Rain"
        edited.frames[1].audio = false
        edited.frames[0].lens = 35
        #expect(edited.text.contains("\"rating\": 5"))
        #expect(edited.text.contains("\"notes\": \"kept\""))
        #expect(edited.text.contains("\"audio\": false"))
        #expect(edited.text.contains("\"lens\": 35"))
        var fresh = FramesFile(scene: "s001")
        fresh.frames.append(StoryboardFrame(file: "01.png"))
        #expect(fresh.text == "{\n  \"scene\": \"s001\",\n  \"frames\": [\n    {\"file\": \"01.png\"}\n  ]\n}\n")
        #expect(fresh.frames[0].audio == false)
    }

    @Test func naming() {
        #expect(StoryboardMedia.nextName(ext: "PNG", existing: []) == "01.png")
        #expect(StoryboardMedia.nextName(ext: "mov", existing: ["01.png", "02.png", "frames.json", "02.strokes.json"]) == "03.mov")
        #expect(StoryboardMedia.freeName("01.png", existing: ["01.png", "01-2.png"]) == "01-3.png")
        #expect(StoryboardMedia.strokesFile(for: "03.png") == "03.strokes.json")
        #expect(StoryboardMedia.isMedia("a.HEIC") && StoryboardMedia.isClip("b.mp4") && !StoryboardMedia.isMedia("frames.json"))
    }

    @Test func timingSharesTheSceneTime() {
        var a = StoryboardFrame(file: "01.png")
        a.duration = 4
        let b = StoryboardFrame(file: "02.png")
        let c = StoryboardFrame(file: "03.png")
        var clip = StoryboardFrame(file: "04.mov")
        clip.inPoint = 1
        clip.outPoint = 3.5
        #expect(FrameTiming.durations([a, b, c, clip], sceneDuration: 12.5) == [4, 3, 3, 2.5])
        // Never under a second, even when the set ones use up the scene.
        #expect(FrameTiming.durations([a, b], sceneDuration: 2) == [4, 1])
        let untrimmed = StoryboardFrame(file: "05.mov")
        #expect(FrameTiming.durations([untrimmed], sceneDuration: 60, clipLength: { _ in 7 }) == [7])
    }

    // MARK: Script ranges

    @Test func rangesResolveBothWays() throws {
        let parsed = ScriptParser.parse(Self.script)
        let scene = parsed.scenes[0]
        let elements = ScriptRange.elements(in: scene, of: parsed).map(\.element.description)
        #expect(elements == ["heading-1", "action-1", "character-1", "parenthetical-1", "dialogue-1", "action-2", "character-2", "dialogue-2"])

        let one = try #require(ScriptRange("action-1"))
        #expect(one.lines(in: scene, of: parsed).map { $0.map { parsed.lines[$0].text } } == ["Rain hammers the window."])
        let span = try #require(ScriptRange("character-1..dialogue-1"))
        #expect(span.description == "character-1..dialogue-1")
        #expect(span.lines(in: scene, of: parsed)?.count == 3)
        // Backwards ends still cover the lines between.
        #expect(ScriptRange("dialogue-1..character-1")?.lines(in: scene, of: parsed)?.count == 3)

        let line = try #require(parsed.lines.firstIndex { $0.text == "She sets the key down." })
        #expect(ScriptRange.element(atLine: line, in: scene, of: parsed)?.description == "action-2")
        #expect(span.covers(line: line, in: scene, of: parsed) == false)
        #expect(ScriptRange("action-9")?.lines(in: scene, of: parsed) == nil)
        #expect(ScriptRange("heading-1")?.start.kind == .sceneHeading)
        #expect(ScriptRange("pagebreak-1")?.start.kind == .pageBreak)
        #expect(ScriptRange("nonsense") == nil)
        #expect(ScriptRange("action-0") == nil)
        #expect(ScriptRange("action-1..x") == nil)
    }

    // MARK: Folders

    @Test func foldersMatchScenes() {
        let paths = [
            "storyboard/storyboard.json",
            "storyboard/scenes/s014 int-kitchen-night/frames.json",
            "storyboard/scenes/s014 int-kitchen-night/01.png",
            "storyboard/scenes/s015 old-name/frames.json",
            "storyboard/scenes/s099 cut-scene/01.png",
            "storyboard/scenes/s014 copy/01.png",
            "storyboard/scenes/notes/readme.txt",
            "storyboard/orphans/s007 old/01.png",
        ]
        let folders = StoryboardFolders.folders(in: paths)
        #expect(folders.count == 6)
        let plan = StoryboardFolders.plan(scenes: [("s014", "INT. KITCHEN - NIGHT"), ("s015", "EXT. ROOF - DAWN"), ("s016", "INT. CAR")],
                                          folders: folders)
        #expect(plan.boarded["s014"]?.name == "s014 int-kitchen-night")
        #expect(plan.renames == [.init(from: "storyboard/scenes/s015 old-name", to: "storyboard/scenes/s015 ext-roof-dawn")])
        #expect(Set(plan.missing.map(\.name)) == ["s099 cut-scene", "notes", "s014 copy"])
        #expect(plan.orphans.map(\.name) == ["s007 old"])
        #expect(plan.unboarded == ["s016"])
        #expect(StoryboardFolders.sceneID(fromFolderName: "s12A fight") == "s12A")
        #expect(StoryboardFolders.sceneID(fromFolderName: "storyboard") == nil)
        #expect(StoryboardFolders.orphanPath(for: SceneFolder(path: "storyboard/scenes/s099 cut-scene"),
                                             existing: ["storyboard/orphans/s099 cut-scene"]) == "storyboard/orphans/s099 cut-scene-2")
    }

    @Test func renamesNeverClobber() {
        let folders = [SceneFolder(path: "storyboard/scenes/s001 old"), SceneFolder(path: "storyboard/scenes/s001 int-car")]
        let plan = StoryboardFolders.plan(scenes: [("s001", "INT. CAR")], folders: folders)
        // Two folders share s001: the one already named for the heading wins, the other is
        // listed as missing, and nothing is renamed onto a taken name.
        #expect(plan.boarded["s001"]?.name == "s001 int-car")
        #expect(plan.renames.isEmpty)
        #expect(plan.missing.map(\.name) == ["s001 old"])
        let clash = StoryboardFolders.plan(scenes: [("s001", "INT. CAR")],
                                           folders: [SceneFolder(path: "storyboard/scenes/s001 old"), SceneFolder(path: "storyboard/orphans/x/s001 int-car")])
        #expect(clash.renames.count == 1)
    }

    // MARK: Sketches

    @Test func strokesRoundTrip() throws {
        var sketch = SketchStrokes(guide: .scope)
        sketch.strokes.append(.init(grey: 0.2, width: 0.004, points: [[0.1, 0.2, 0.5], [0.123456, 0.3, 1]]))
        sketch.strokes.append(.init(grey: 1, width: 0.02, erase: true, points: [[0.5, 0.5, 1]]))
        let read = try SketchStrokes(data: sketch.data)
        #expect(read.guide == .scope)
        #expect(read.strokes[0].points[1][0] == 0.123)
        #expect(read.strokes[1].erase)
        #expect(String(decoding: sketch.data, as: UTF8.self).hasPrefix("{\"guide\":\"2.39:1\""))
        #expect(SketchGuide.flat.ratio == 1.85)
    }
}
