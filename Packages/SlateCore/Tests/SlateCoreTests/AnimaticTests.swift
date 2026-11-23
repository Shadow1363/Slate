import Foundation
import Testing
@testable import SlateCore

@Suite("Animatic")
struct AnimaticTests {
    static let script = """
    INT. KITCHEN - NIGHT {#s014 dur=0:12}

    Rain hammers the window.

    MARA
    (quietly)
    I haven't opened it yet.

    She sets the key down.

    OLDER MARA (O.S.)
    You already have.

    EXT. ROOF - DAWN {#s015 dur=0:04}

    Wind.
    """

    static let folder = "storyboard/scenes/s014 int-kitchen-night"

    static func frames(_ edit: (inout FramesFile) -> Void = { _ in }) -> FramesFile {
        var file = FramesFile(scene: "s014")
        var first = StoryboardFrame(file: "01.png")
        first.duration = 3
        first.scriptRange = "action-1"
        first.caption = "Rain"
        var second = StoryboardFrame(file: "02.png")
        second.scriptRange = "character-1..dialogue-1"
        file.frames = [first, second, StoryboardFrame(file: "03.png")]
        edit(&file)
        return file
    }

    static func timeline(frames: FramesFile = frames(), settings: StoryboardSettings = StoryboardSettings(),
                         range: AnimaticRange = .film, clipLength: @escaping (String) -> Double? = { _ in nil }) -> AnimaticTimeline {
        let book = ScriptBook(texts: [(path: "script/script.md", text: script)])
        let scenes = AnimaticScene.all(in: book, boards: ["s014": (folder, frames)])
        return AnimaticTimeline.build(scenes: scenes, settings: settings, range: range, clipLength: clipLength)
    }

    // MARK: Segments

    @Test func segmentsFollowFrameTimingAndPlaceholders() {
        let film = Self.timeline()
        #expect(film.segments.map(\.start) == [0, 3, 7.5, 12])
        #expect(film.segments.map(\.duration) == [3, 4.5, 4.5, 4])
        #expect(film.duration == 16)
        #expect(film.segments[0].content == .image(Self.folder + "/01.png"))
        #expect(film.segments[0].caption == "Rain")
        #expect(film.segments[3].content == .placeholder("Wind."))
        #expect(film.segments[3].sceneNumber == "2")
        #expect(film.segments[3].file == nil)
        #expect(film.sceneStarts.map(\.start) == [0, 12])
        #expect(film.segment(at: 5)?.file == "02.png")
        #expect(film.segment(at: 100)?.sceneID == "s015")
        #expect(film.segmentIndex(at: 7.5) == 2)
    }

    @Test func clipsPlayTheirTrim() {
        let frames = Self.frames {
            var clip = StoryboardFrame(file: "04.mov")
            clip.inPoint = 1
            clip.outPoint = 3
            $0.frames.append(clip)
        }
        let film = Self.timeline(frames: frames)
        let clip = film.segments[3]
        #expect(clip.content == .clip(Self.folder + "/04.mov", start: 1, audio: true))
        #expect(clip.duration == 2)
        #expect(clip.motion == .none)
        // The other unset frames share what's left: (12 - 3 - 2) / 2.
        #expect(film.segments[1].duration == 3.5)
    }

    @Test func motionComesFromMoveOrTheSetting() {
        let frames = Self.frames {
            $0.frames[0].move = "pull out"
            $0.frames[1].move = "static"
        }
        var settings = StoryboardSettings()
        #expect(Self.timeline(frames: frames, settings: settings).segments.map(\.motion) == [.pullOut, .none, .none, .none])
        settings.pushIn = true
        #expect(Self.timeline(frames: frames, settings: settings).segments.map(\.motion) == [.pullOut, .none, .pushIn, .none])
        #expect(FrameMotion.pushIn.scale(at: 0.5) == 1.05)
        #expect(FrameMotion.pullOut.scale(at: 1) == 1)
        #expect(FrameMotion(move: "Push In") == .pushIn)
    }

    // MARK: Subtitles

    @Test func coveredDialogueShowsDuringItsFrame() {
        let film = Self.timeline()
        #expect(film.subtitles.count == 2)
        let mara = film.subtitles[0]
        #expect(mara.character == "MARA")
        #expect(mara.text == "(quietly) I haven't opened it yet.")
        #expect(mara.start == 3)
        #expect(mara.end == 7.5)
        #expect(film.cue(at: 4)?.character == "MARA")
    }

    @Test func uncoveredDialogueFallsWhereItIsInTheScene() {
        let film = Self.timeline()
        let older = film.subtitles[1]
        #expect(older.character == "OLDER MARA")
        #expect(older.text == "You already have.")
        // Most of the scene's words come before it, so it plays near the end.
        #expect(older.start > 7.5)
        #expect(older.end == 12)
        #expect(film.cue(at: 12.5) == nil)
    }

    @Test func oneFrameCoveringTwoSpeechesSplitsByWords() {
        let frames = Self.frames { $0.frames[1].scriptRange = "character-1..dialogue-2" }
        let film = Self.timeline(frames: frames)
        #expect(film.subtitles.count == 2)
        // "I haven't opened it yet." (5 words) and "You already have." (3) share 4.5 s.
        #expect(film.subtitles[0].end == 5.813) // 3 + 4.5 × 5/8, to the millisecond
        #expect(film.subtitles[1].start == film.subtitles[0].end)
        #expect(film.subtitles[1].end == 7.5)
    }

    @Test func emptySceneStillGetsSubtitles() {
        let film = Self.timeline(frames: FramesFile(scene: "s014"))
        #expect(film.segments.count == 2)
        #expect(film.subtitles.count == 2)
        #expect(film.subtitles.allSatisfy { $0.end <= 12 })
        #expect(AnimaticTimeline.cueName("OLDER MARA (O.S.)") == "OLDER MARA")
        #expect(AnimaticTimeline.cueName("MARA ^") == "MARA")
    }

    // MARK: Ranges and audio

    @Test func rangesCutTheFilm() {
        let scene = Self.timeline(range: .scene("s015"))
        #expect(scene.segments.count == 1)
        #expect(scene.segments[0].start == 0)
        #expect(scene.duration == 4)
        #expect(scene.subtitles.isEmpty)

        let both = Self.timeline(range: .scenes(from: "s015", to: "s014"))
        #expect(both.duration == 16)
        #expect(both.segments.count == 4)

        let fromFrame = Self.timeline(range: .fromFrame(scene: "s014", file: "02.png"))
        #expect(fromFrame.segments.map(\.file) == ["02.png", "03.png", nil])
        #expect(fromFrame.segments.map(\.start) == [0, 4.5, 9])
        #expect(fromFrame.duration == 13)
        #expect(fromFrame.subtitles.first?.start == 0)

        #expect(Self.timeline(range: .scene("s999")).segments.isEmpty)
    }

    @Test func scratchAudioAndScore() {
        let frames = Self.frames {
            $0.scratchAudio = "scratch.m4a"
            $0.scratchVolume = 0.5
        }
        var settings = StoryboardSettings()
        settings.score = "score.m4a"
        settings.scoreVolume = 0.6
        let film = Self.timeline(frames: frames, settings: settings)
        #expect(film.audio == [
            AudioPlacement(kind: .scratch, path: Self.folder + "/scratch.m4a", start: 0, duration: 12, offset: 0, volume: 0.5),
            AudioPlacement(kind: .score, path: "storyboard/score.m4a", start: 0, duration: 16, offset: 0, volume: 0.6),
        ])
        #expect(film.mediaPaths.contains("storyboard/score.m4a"))

        let late = Self.timeline(frames: frames, settings: settings, range: .fromFrame(scene: "s014", file: "02.png"))
        #expect(late.audio[0].offset == 3)
        #expect(late.audio[0].duration == 9)
        #expect(late.audio[1].offset == 3)
        #expect(late.audio[1].duration == 13)

        let roof = Self.timeline(frames: frames, settings: settings, range: .scene("s015"))
        #expect(roof.audio.map(\.kind) == [.score])
        #expect(roof.audio[0].offset == 12)
    }

    // MARK: Files

    @Test func framesAudioKeysRoundTrip() throws {
        let text = """
        {
          "scene": "s014",
          "audio": "scratch.m4a",
          "audioVolume": 0.8,
          "frames": [
            {"file": "01.png", "audio": false}
          ],
          "notes": "kept"
        }

        """
        let file = try FramesFile(text: text)
        #expect(file.text == text)
        #expect(file.scratchAudio == "scratch.m4a")
        #expect(file.scratchVolume == 0.8)
        #expect(file.frames[0].audio == false)
        var edited = file
        edited.scratchAudio = nil
        edited.scratchVolume = nil
        #expect(!edited.text.contains("scratch"))
        #expect(edited.text.contains("\"notes\": \"kept\""))
        #expect(StoryboardMedia.isAudio("scratch.M4A"))
        #expect(!StoryboardMedia.isMedia("scratch.m4a"))
    }

    @Test func storyboardSettingsRoundTrip() throws {
        let text = """
        {
          "scenes": [],
          "settings": {"guide": "2.39:1", "score": "score.m4a", "scoreVolume": 0.6, "pushIn": true, "extra": 1}
        }

        """
        let settings = try StoryboardSettings(text: text)
        #expect(settings.guide == .scope)
        #expect(settings.score == "score.m4a")
        #expect(settings.scorePath == "storyboard/score.m4a")
        #expect(settings.scoreVolume == 0.6)
        #expect(settings.pushIn)
        #expect(try StoryboardSettings(text: settings.text) == settings)
        var edited = settings
        edited.pushIn = false
        edited.score = nil
        #expect(!edited.text.contains("pushIn"))
        #expect(edited.text.contains("\"extra\": 1"))
        #expect(try StoryboardSettings(text: "").guide == .wide)
        // The layout Slate wrote before Milestone 10 still reads.
        let old = try StoryboardSettings(text: "{\n  \"scenes\" : [\n\n  ],\n  \"settings\" : {\n    \"guide\" : \"1.85:1\"\n  }\n}\n")
        #expect(old.guide == .flat)
    }
}

@Suite("Animatic text")
struct AnimaticTextTests {
    @Test func subtitlesAndPlaceholdersDropMarkup() {
        let script = """
        INT. ROOM - NIGHT {#s001}

        She opens [[The Brass Key|the box]] *slowly*.

        JUNO
        _Ellis!_ It's **[[Ellis]]**.
        """
        let book = ScriptBook(texts: [(path: "script/script.md", text: script)])
        let film = AnimaticTimeline.build(scenes: AnimaticScene.all(in: book, boards: [:]))
        #expect(film.segments.first?.content == .placeholder("She opens the box slowly."))
        #expect(film.subtitles.first?.text == "Ellis! It's Ellis.")
    }
}

@Suite("Animatic subtitles")
struct AnimaticReadabilityTests {
    @Test func shortPlacedCuesSpreadIntoFreeTime() {
        let cues = [
            SubtitleCue(start: 8, end: 8.4, character: "A", text: "Did you now."),
            SubtitleCue(start: 8.4, end: 8.8, character: "B", text: "Felt like I owed her something."),
        ]
        let spread = AnimaticTimeline.readable(cues, covered: [false, false], from: 0, to: 10)
        #expect(spread[0].end - spread[0].start >= 1.8)
        #expect(spread[1].start == spread[0].end)
        #expect(spread[1].end <= 10)
        #expect(spread[1].end - spread[1].start > spread[0].end - spread[0].start)
        // A covered cue keeps its time, and blocks the run from spreading over it.
        let kept = AnimaticTimeline.readable(cues, covered: [true, false], from: 0, to: 10)
        #expect(kept[0] == cues[0])
        #expect(kept[1].start >= kept[0].end) // spreads only after the covered cue
        // No room: the run fills what there is.
        let tight = AnimaticTimeline.readable(cues, covered: [false, false], from: 8, to: 9)
        #expect(tight.first?.start == 8)
        #expect(tight.last?.end == 9)
        #expect(AnimaticTimeline.readingTime("one two three") == 1.9)
    }
}
