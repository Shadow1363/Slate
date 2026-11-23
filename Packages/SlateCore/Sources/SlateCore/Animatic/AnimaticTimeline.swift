import Foundation

/// What to play: the whole film, one scene, a run of scenes, or from a frame to the end.
public enum AnimaticRange: Sendable, Equatable, Hashable {
    case film
    case scene(String)
    /// Inclusive, in script order (either way round).
    case scenes(from: String, to: String)
    /// From a frame (by scene ID and file name) to the end of the film.
    case fromFrame(scene: String, file: String)
}

/// A slow scale over a still: in (100 → 110%) or out (110 → 100%).
public enum FrameMotion: String, Sendable, Equatable {
    case none, pushIn, pullOut

    /// `move` values that mean a push-in or pull-out.
    public init(move: String?) {
        switch move?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "push in", "push-in", "pushin", "dolly in": self = .pushIn
        case "pull out", "pull-out", "pullout", "dolly out": self = .pullOut
        default: self = .none
        }
    }

    /// The scale at `progress` (0–1) through the frame.
    public func scale(at progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        switch self {
        case .none: return 1
        case .pushIn: return 1 + 0.1 * p
        case .pullOut: return 1.1 - 0.1 * p
        }
    }
}

/// One stretch of the animatic: a frame of a scene, or an empty scene's placeholder.
public struct AnimaticSegment: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        /// An image, by path from the project root.
        case image(String)
        /// A clip from `start` seconds into the file; `audio` plays its sound.
        case clip(String, start: Double, audio: Bool)
        /// An empty scene: its first action line (or heading).
        case placeholder(String)

        public var path: String? {
            switch self {
            case .image(let path), .clip(let path, _, _): path
            case .placeholder: nil
            }
        }
    }

    public let sceneID: String
    /// The printed scene number (`14`, `14A`).
    public let sceneNumber: String
    public let heading: String
    /// The scene folder and frame file, for frames.
    public let folder: String?
    public let file: String?
    /// 0-based position among the scene's frames.
    public let frameIndex: Int
    public var content: Content
    public var start: Double
    public var duration: Double
    public var caption: String?
    public var shot: String?
    public var move: String?
    public var motion: FrameMotion

    public var id: String { "\(sceneID)#\(frameIndex)" }
    public var end: Double { start + duration }
}

/// A line of dialogue shown as a subtitle.
public struct SubtitleCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// The speaker, without extensions such as `(O.S.)`.
    public var character: String
    /// Parentheticals and dialogue, joined into one paragraph.
    public var text: String

    public init(start: Double, end: Double, character: String, text: String) {
        self.start = start
        self.end = end
        self.character = character
        self.text = text
    }
}

/// A sound file placed on the animatic's timeline.
public struct AudioPlacement: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case scratch, score }

    public var kind: Kind
    /// From the project root.
    public var path: String
    /// Where it starts on the timeline.
    public var start: Double
    /// How long it plays (cut short if the file is shorter).
    public var duration: Double
    /// Seconds into the file where it starts.
    public var offset: Double
    public var volume: Double
}

/// One scene's input for `AnimaticTimeline.build`.
public struct AnimaticScene: Sendable {
    public let scene: ScriptBook.Scene
    public let parsed: ParsedScript
    /// The scene's board folder and its frames, if it has one.
    public let folder: String?
    public let frames: FramesFile?

    public init(scene: ScriptBook.Scene, parsed: ParsedScript, folder: String?, frames: FramesFile?) {
        self.scene = scene
        self.parsed = parsed
        self.folder = folder
        self.frames = frames
    }

    public var id: String { scene.scene.sceneID ?? scene.id }

    /// The scenes with IDs, in script order, with their boards.
    /// - Parameter boards: Scene ID → its board folder and frames.
    public static func all(in book: ScriptBook, boards: [String: (folder: String, frames: FramesFile)]) -> [AnimaticScene] {
        book.scenes.compactMap { scene in
            guard let id = scene.scene.sceneID,
                  let parsed = book.files.first(where: { $0.path == scene.file })?.parsed else { return nil }
            let board = boards[id]
            return AnimaticScene(scene: scene, parsed: parsed, folder: board?.folder, frames: board?.frames)
        }
    }
}

/// The animatic as a plan: frames, subtitles and sound on one timeline. Pure
/// data, built from the script and the boards; SlateExport turns it into video.
public struct AnimaticTimeline: Sendable, Equatable {
    public var segments: [AnimaticSegment]
    public var subtitles: [SubtitleCue]
    public var audio: [AudioPlacement]
    public var duration: Double
    /// The storyboard's guide, the shape frames are shown in.
    public var guide: SketchGuide

    public init(segments: [AnimaticSegment] = [], subtitles: [SubtitleCue] = [], audio: [AudioPlacement] = [],
                duration: Double = 0, guide: SketchGuide = .wide) {
        self.segments = segments
        self.subtitles = subtitles
        self.audio = audio
        self.duration = duration
        self.guide = guide
    }

    /// The segment playing at `time` (the last one at or past the end).
    public func segment(at time: Double) -> AnimaticSegment? {
        guard !segments.isEmpty else { return nil }
        return segments.last { $0.start <= time + 0.0001 } ?? segments.first
    }

    public func segmentIndex(at time: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        return segments.lastIndex { $0.start <= time + 0.0001 } ?? 0
    }

    /// The subtitle showing at `time`, if any.
    public func cue(at time: Double) -> SubtitleCue? {
        subtitles.last { $0.start <= time && time < $0.end }
    }

    /// Where each scene starts, in order.
    public var sceneStarts: [(sceneID: String, start: Double)] {
        var result: [(sceneID: String, start: Double)] = []
        for segment in segments where result.last?.sceneID != segment.sceneID {
            result.append((segment.sceneID, segment.start))
        }
        return result
    }

    /// Every media file it plays, from the project root.
    public var mediaPaths: [String] {
        segments.compactMap(\.content.path) + audio.map(\.path)
    }

    // MARK: - Building

    /// Plans the animatic.
    /// - Parameters:
    ///   - scenes: Every scene with an ID, in script order.
    ///   - clipLength: A clip's full length in seconds, by path from the project root, if known.
    public static func build(scenes: [AnimaticScene], settings: StoryboardSettings = StoryboardSettings(),
                             range: AnimaticRange = .film,
                             clipLength: (String) -> Double? = { _ in nil }) -> AnimaticTimeline {
        var film = AnimaticTimeline(guide: settings.guide)
        var time = 0.0
        for scene in scenes {
            let length = add(scene, at: time, settings: settings, clipLength: clipLength, to: &film)
            time += length
        }
        film.duration = time
        if let score = settings.scorePath, time > 0 {
            film.audio.append(AudioPlacement(kind: .score, path: score, start: 0, duration: time, offset: 0,
                                             volume: settings.scoreVolume ?? 1))
        }
        guard let window = window(for: range, in: film) else { return AnimaticTimeline(guide: settings.guide) }
        return film.cut(from: window.lowerBound, to: window.upperBound)
    }

    /// Adds a scene's segments, subtitles and scratch audio; returns its length.
    private static func add(_ input: AnimaticScene, at start: Double, settings: StoryboardSettings,
                            clipLength: (String) -> Double?, to film: inout AnimaticTimeline) -> Double {
        let scene = input.scene
        let id = input.id
        let frames = input.frames?.frames ?? []
        let folder = input.folder
        func path(_ file: String) -> String { (folder.map { $0 + "/" } ?? "") + file }

        var segments: [AnimaticSegment] = []
        if frames.isEmpty || folder == nil {
            segments.append(AnimaticSegment(
                sceneID: id, sceneNumber: scene.label, heading: scene.scene.heading, folder: folder, file: nil,
                frameIndex: 0, content: .placeholder(firstAction(of: input) ?? scene.scene.heading),
                start: start, duration: max(scene.duration, 1), caption: nil, shot: nil, move: nil, motion: .none))
        } else {
            let durations = FrameTiming.durations(frames, sceneDuration: scene.duration) { clipLength(path($0)) }
            var time = start
            for (index, frame) in frames.enumerated() {
                let content: AnimaticSegment.Content = frame.isClip
                    ? .clip(path(frame.file), start: frame.inPoint ?? 0, audio: frame.audio)
                    : .image(path(frame.file))
                var motion = FrameMotion(move: frame.move)
                if motion == .none, !frame.isClip, frame.move == nil, settings.pushIn { motion = .pushIn }
                if frame.isClip { motion = .none }
                segments.append(AnimaticSegment(
                    sceneID: id, sceneNumber: scene.label, heading: scene.scene.heading, folder: folder, file: frame.file,
                    frameIndex: index, content: content, start: time, duration: durations[index],
                    caption: frame.caption, shot: frame.shot, move: frame.move, motion: motion))
                time += durations[index]
            }
        }
        let length = segments.reduce(0) { $0 + $1.duration }
        film.segments += segments
        film.subtitles += subtitles(for: input, segments: segments, start: start, length: length)
        if let audio = input.frames?.scratchAudio, folder != nil {
            film.audio.append(AudioPlacement(kind: .scratch, path: path(audio), start: start, duration: length,
                                             offset: 0, volume: input.frames?.scratchVolume ?? 1))
        }
        return length
    }

    private static func firstAction(of input: AnimaticScene) -> String? {
        input.scene.scene.lines.lazy
            .filter { input.parsed.lines.indices.contains($0) }
            .map { input.parsed.lines[$0] }
            .first { $0.kind == .action && !$0.isEmpty }
            .map(plainText(of:))
    }

    /// A line as it would print, without emphasis marks or link brackets.
    static func plainText(of line: ScriptLine) -> String {
        Emphasis.runs(in: Emphasis.printable(ScriptEstimate.printedText(of: line))).map(\.text).joined()
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Subtitles

    /// A character's speech: the cue and the lines under it.
    struct Speech {
        var character: String
        var lines: [Int]
        var parts: [String]
        var words: Int
    }

    static func speeches(in scene: ScriptScene, of parsed: ParsedScript) -> [Speech] {
        var result: [Speech] = []
        var current: Speech?
        for index in scene.lines where parsed.lines.indices.contains(index) {
            let line = parsed.lines[index]
            switch line.kind {
            case .character:
                if let current { result.append(current) }
                current = Speech(character: cueName(plainText(of: line)), lines: [index], parts: [], words: 0)
            case .parenthetical, .dialogue:
                guard current != nil else { continue }
                let text = plainText(of: line)
                current?.lines.append(index)
                if !text.isEmpty { current?.parts.append(text) }
                if line.kind != .parenthetical { current?.words += ScriptEstimate.words(in: line) }
            case .blank:
                continue
            default:
                if let current { result.append(current) }
                current = nil
            }
        }
        if let current { result.append(current) }
        return result.filter { !$0.parts.isEmpty }
    }

    /// `OLDER MARA (O.S.)` → `OLDER MARA`; drops the dual-dialogue `^`.
    static func cueName(_ cue: String) -> String {
        var name = cue.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("^") { name.removeLast() }
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Dialogue a frame's `scriptRange` covers shows during that frame (split by
    /// word count when it covers several speeches). Other dialogue is placed by
    /// where it falls in the scene, weighted by word count.
    static func subtitles(for input: AnimaticScene, segments: [AnimaticSegment], start: Double, length: Double) -> [SubtitleCue] {
        let scene = input.scene.scene, parsed = input.parsed
        let speeches = speeches(in: scene, of: parsed)
        guard !speeches.isEmpty, length > 0 else { return [] }

        // Which frame (segment) shows each speech.
        let covered: [[Int]] = segments.map { segment in
            guard let file = segment.file,
                  let frame = input.frames?.frames.first(where: { $0.file == file }),
                  let range = frame.scriptRange.flatMap(ScriptRange.init),
                  let lines = range.lines(in: scene, of: parsed) else { return [] }
            return Array(Set(lines))
        }
        var owner: [Int?] = Array(repeating: nil, count: speeches.count)
        for (index, speech) in speeches.enumerated() {
            owner[index] = covered.firstIndex { lines in speech.lines.contains { lines.contains($0) } }
        }

        var cues: [(order: Int, cue: SubtitleCue)] = []
        // Covered speeches share their frame's time by word count.
        for (segmentIndex, segment) in segments.enumerated() {
            let mine = speeches.indices.filter { owner[$0] == segmentIndex }
            let total = mine.reduce(0.0) { $0 + Double(max(speeches[$1].words, 1)) }
            var time = segment.start
            for index in mine {
                let share = segment.duration * Double(max(speeches[index].words, 1)) / total
                cues.append((index, cue(speeches[index], time, time + share)))
                time += share
            }
        }
        // The rest go where they fall in the scene, by the words before them.
        let elements = ScriptRange.elements(in: scene, of: parsed).map(\.line)
        let weights = elements.map { Double(max(ScriptEstimate.words(in: parsed.lines[$0]), 1)) }
        let totalWeight = weights.reduce(0, +)
        func position(_ line: Int) -> Double {
            guard totalWeight > 0, let index = elements.firstIndex(of: line) else { return 0 }
            return weights[..<index].reduce(0, +) / totalWeight
        }
        for (index, speech) in speeches.enumerated() where owner[index] == nil {
            let first = speech.lines.first!, last = speech.lines.last!
            let from = position(first)
            let to = position(last) + (elements.firstIndex(of: last).map { weights[$0] } ?? 0) / max(totalWeight, 1)
            cues.append((index, cue(speech, start + from * length, start + min(to, 1) * length)))
        }

        // In script order, never overlapping.
        var ordered = cues.sorted { $0.cue.start != $1.cue.start ? $0.cue.start < $1.cue.start : $0.order < $1.order }.map(\.cue)
        for index in ordered.indices.dropLast() where ordered[index].end > ordered[index + 1].start {
            ordered[index].end = ordered[index + 1].start
        }
        return ordered.filter { $0.end - $0.start > 0.05 }
    }

    private static func cue(_ speech: Speech, _ start: Double, _ end: Double) -> SubtitleCue {
        SubtitleCue(start: round(start), end: round(end), character: speech.character, text: speech.parts.joined(separator: " "))
    }

    private static func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    // MARK: Ranges

    /// The stretch of the film a range plays.
    static func window(for range: AnimaticRange, in film: AnimaticTimeline) -> ClosedRange<Double>? {
        let starts = film.sceneStarts
        func span(_ id: String) -> ClosedRange<Double>? {
            guard let index = starts.firstIndex(where: { $0.sceneID == id }) else { return nil }
            let end = index + 1 < starts.count ? starts[index + 1].start : film.duration
            return starts[index].start...end
        }
        switch range {
        case .film:
            return 0...film.duration
        case .scene(let id):
            return span(id)
        case .scenes(let from, let to):
            guard let a = span(from), let b = span(to) else { return nil }
            return min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
        case .fromFrame(let scene, let file):
            guard let segment = film.segments.first(where: { $0.sceneID == scene && $0.file == file })
                ?? film.segments.first(where: { $0.sceneID == scene }) else { return nil }
            return segment.start...film.duration
        }
    }

    /// The part between two segment boundaries, moved to start at 0.
    func cut(from lower: Double, to upper: Double) -> AnimaticTimeline {
        let epsilon = 0.0001
        var result = AnimaticTimeline(guide: guide)
        result.segments = segments.filter { $0.start >= lower - epsilon && $0.end <= upper + epsilon }.map {
            var segment = $0
            segment.start = Self.round(segment.start - lower)
            return segment
        }
        result.subtitles = subtitles.compactMap { cue in
            let start = max(cue.start, lower), end = min(cue.end, upper)
            guard end - start > 0.05 else { return nil }
            return SubtitleCue(start: Self.round(start - lower), end: Self.round(end - lower), character: cue.character, text: cue.text)
        }
        result.audio = audio.compactMap { placement in
            let start = max(placement.start, lower), end = min(placement.start + placement.duration, upper)
            guard end - start > 0.05 else { return nil }
            var cut = placement
            cut.offset = placement.offset + (start - placement.start)
            cut.start = Self.round(start - lower)
            cut.duration = Self.round(end - start)
            return cut
        }
        result.duration = Self.round(upper - lower)
        return result
    }
}
