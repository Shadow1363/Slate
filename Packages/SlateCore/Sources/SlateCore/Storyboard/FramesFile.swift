import Foundation

/// Shot sizes, widest first.
public enum ShotSize: String, Sendable, CaseIterable, Identifiable {
    case ews = "EWS", ws = "WS", ms = "MS", mcu = "MCU", cu = "CU", ecu = "ECU", insert = "INSERT"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ews: "Extreme wide"
        case .ws: "Wide"
        case .ms: "Medium"
        case .mcu: "Medium close-up"
        case .cu: "Close-up"
        case .ecu: "Extreme close-up"
        case .insert: "Insert"
        }
    }

    /// Case-insensitive, so `cu` and `insert` read too.
    public init?(reading text: String) {
        self.init(rawValue: text.uppercased())
    }
}

/// Camera moves offered in the inspector. Files may hold any other word.
public enum CameraMove: String, Sendable, CaseIterable, Identifiable {
    case still = "static", pan, tilt, pushIn = "push in", pullOut = "pull out", track, handheld, crane, zoom

    public var id: String { rawValue }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// One frame of a scene's board: an image, a clip or a sketch.
public struct StoryboardFrame: Sendable, Equatable, Identifiable {
    public var object: JSONObject

    public init(object: JSONObject) { self.object = object }

    public init(file: String) {
        object = JSONObject([("file", .string(file))])
    }

    /// The media file, relative to the scene folder (`01.png`).
    public var file: String {
        get { object.text("file") ?? "" }
        set { object.setText("file", newValue) }
    }

    public var id: String { file }

    public var isClip: Bool { StoryboardMedia.isClip(file) }

    /// Seconds on screen; nil shares the scene's time with other unset frames.
    public var duration: Double? {
        get { number("duration") }
        set { setNumber("duration", newValue) }
    }

    /// Clip trim, in seconds.
    public var inPoint: Double? {
        get { number("in") }
        set { setNumber("in", newValue) }
    }

    public var outPoint: Double? {
        get { number("out") }
        set { setNumber("out", newValue) }
    }

    /// `WS`, `CU`… (see `ShotSize`), or anything written by hand.
    public var shot: String? {
        get { object.text("shot") }
        set { object.setText("shot", newValue) }
    }

    public var move: String? {
        get { object.text("move") }
        set { object.setText("move", newValue) }
    }

    /// Focal length in mm.
    public var lens: Double? {
        get { number("lens") }
        set { setNumber("lens", newValue) }
    }

    public var caption: String? {
        get { object.text("caption") }
        set { object.setText("caption", newValue) }
    }

    /// Which script lines it covers: `action-1` or `action-1..dialogue-2`.
    public var scriptRange: String? {
        get { object.text("scriptRange") }
        set { object.setText("scriptRange", newValue) }
    }

    /// Whether a clip plays its own sound.
    public var audio: Bool {
        get { object["audio"]?.bool ?? isClip }
        set { object["audio"] = newValue == isClip ? nil : .bool(newValue) }
    }

    private func number(_ key: String) -> Double? {
        object[key]?.double
    }

    private mutating func setNumber(_ key: String, _ value: Double?) {
        object[key] = value.map { .number(($0 * 1000).rounded() / 1000) }
    }
}

/// `frames.json` in a scene folder: the order and details of its frames.
public struct FramesFile: TextBackedFile {
    public var root: JSONObject
    public var frames: [StoryboardFrame]

    public static let name = "frames.json"

    public init(scene: String) {
        root = JSONObject([("scene", .string(scene))])
        frames = []
    }

    public init(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.init(scene: "")
            return
        }
        guard case .object(let root) = try OrderedJSON.parse(text) else {
            throw OrderedJSON.ParseError(message: "frames.json must be a JSON object", offset: 0)
        }
        self.init(root: root)
    }

    public init(root: JSONObject) {
        self.root = root
        frames = (root["frames"]?.array ?? []).compactMap(\.object).map(StoryboardFrame.init(object:))
    }

    public var composed: JSONObject {
        var object = root
        object["frames"] = .array(frames.map { .object($0.object) })
        return object
    }

    public var text: String { OrderedJSON.object(composed).pretty() + "\n" }

    public static func == (lhs: FramesFile, rhs: FramesFile) -> Bool { lhs.composed == rhs.composed }

    /// The scene ID it belongs to.
    public var scene: String {
        get { root.text("scene") ?? "" }
        set { root.setText("scene", newValue) }
    }

    public func index(of file: String) -> Int? { frames.firstIndex { $0.file == file } }

    /// The scene's scratch audio (temp music, a recorded read), in its folder:
    /// `"audio": "scratch.m4a"`.
    public var scratchAudio: String? {
        get { root.text("audio") }
        set { root.setText("audio", newValue) }
    }

    /// 0–1; nil plays at full volume.
    public var scratchVolume: Double? {
        get { root["audioVolume"]?.double }
        set { root["audioVolume"] = newValue.map { .number(($0 * 100).rounded() / 100) } }
    }
}

/// Which files can be frames.
public enum StoryboardMedia {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp"]
    public static let clipExtensions: Set<String> = ["mov", "mp4", "m4v"]
    /// Scratch audio and temp score. Never frames.
    public static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf"]

    public static func isAudio(_ path: String) -> Bool {
        audioExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func isClip(_ path: String) -> Bool {
        clipExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func isMedia(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || clipExtensions.contains(ext)
    }

    /// The strokes file kept beside a sketch: `03.png` → `03.strokes.json`.
    public static func strokesFile(for file: String) -> String {
        (file as NSString).deletingPathExtension + SketchStrokes.suffix
    }

    /// The next free `NN.ext` among `existing` file names (`01.png`, `02.mov`…).
    public static func nextName(ext: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { ($0 as NSString).deletingPathExtension.lowercased() })
        var number = existing.compactMap { Int(($0 as NSString).deletingPathExtension) }.max().map { $0 + 1 } ?? 1
        while taken.contains(String(format: "%02d", number)) { number += 1 }
        return String(format: "%02d", number) + "." + ext.lowercased()
    }

    /// `name`, or `name-2`, `name-3`… if it's taken.
    public static func freeName(_ name: String, existing: Set<String>) -> String {
        let lowered = Set(existing.map { $0.lowercased() })
        guard lowered.contains(name.lowercased()) else { return name }
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = "\(stem)-\(counter)" + (ext.isEmpty ? "" : ".\(ext)")
            if !lowered.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }
}

/// How long each frame is on screen.
public enum FrameTiming {
    /// Set durations stand; clips without one play their trim (or full length);
    /// the rest share what's left of the scene's estimated time, at least a second each.
    /// - Parameter clipLength: The full length of a clip, if known.
    public static func durations(_ frames: [StoryboardFrame], sceneDuration: Double,
                                 clipLength: (String) -> Double? = { _ in nil }) -> [Double] {
        var fixed: [Double?] = frames.map { frame in
            if let duration = frame.duration { return duration }
            guard frame.isClip else { return nil }
            let start = frame.inPoint ?? 0
            if let end = frame.outPoint ?? clipLength(frame.file) { return max(end - start, 0.1) }
            return nil
        }
        let used = fixed.compactMap { $0 }.reduce(0, +)
        let open = fixed.filter { $0 == nil }.count
        let share = open == 0 ? 0 : max((sceneDuration - used) / Double(open), 1)
        for index in fixed.indices where fixed[index] == nil { fixed[index] = (share * 10).rounded() / 10 }
        return fixed.map { $0 ?? share }
    }
}
