import Foundation

/// `storyboard/storyboard.json`: board-wide settings. Read and written like
/// `frames.json`: key order and unknown keys are kept.
///
/// ```json
/// { "settings": { "guide": "2.39:1", "score": "score.m4a", "scoreVolume": 0.6, "pushIn": true } }
/// ```
public struct StoryboardSettings: TextBackedFile {
    public var root: JSONObject

    public init() { root = JSONObject([("settings", .object(JSONObject()))]) }

    public init(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.init()
            return
        }
        guard case .object(let root) = try OrderedJSON.parse(text) else {
            throw OrderedJSON.ParseError(message: "storyboard.json must be a JSON object", offset: 0)
        }
        self.init(root: root)
    }

    public init(root: JSONObject) { self.root = root }

    public var text: String { OrderedJSON.object(root).pretty() + "\n" }

    private var settings: JSONObject {
        get { root["settings"]?.object ?? JSONObject() }
        set { root["settings"] = .object(newValue) }
    }

    /// The sketch pad's default guide.
    public var guide: SketchGuide {
        get { settings["guide"]?.string.flatMap(SketchGuide.init(rawValue:)) ?? .wide }
        set { settings["guide"] = .string(newValue.rawValue) }
    }

    /// The project-wide temp score, relative to `storyboard/`.
    public var score: String? {
        get { settings.text("score") }
        set { settings.setText("score", newValue) }
    }

    /// 0–1; nil plays at full volume.
    public var scoreVolume: Double? {
        get { settings["scoreVolume"]?.double }
        set { settings["scoreVolume"] = newValue.map { .number(($0 * 100).rounded() / 100) } }
    }

    /// A slow push-in on every still frame that doesn't set its own move.
    public var pushIn: Bool {
        get { settings["pushIn"]?.bool ?? false }
        set { settings["pushIn"] = newValue ? .bool(true) : nil }
    }

    /// The score's path from the project root.
    public var scorePath: String? { score.map { "storyboard/" + $0 } }
}
