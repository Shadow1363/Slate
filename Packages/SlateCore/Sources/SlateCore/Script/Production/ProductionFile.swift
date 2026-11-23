import Foundation

/// The standard order of revision page colours.
public enum RevisionColor: String, Sendable, CaseIterable, Identifiable {
    case white = "White", blue = "Blue", pink = "Pink", yellow = "Yellow", green = "Green"
    case goldenrod = "Goldenrod", buff = "Buff", salmon = "Salmon", cherry = "Cherry"

    public var id: String { rawValue }

    /// The colour after this one; after Cherry the cycle starts again ("Double White" in practice).
    public var next: RevisionColor {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return all[(index + 1) % all.count]
    }

    /// The page tint, as sRGB 0–1 (very light, so text stays readable).
    public var tint: (red: Double, green: Double, blue: Double) {
        switch self {
        case .white: (1, 1, 1)
        case .blue: (0.86, 0.92, 1)
        case .pink: (1, 0.88, 0.92)
        case .yellow: (1, 0.98, 0.8)
        case .green: (0.88, 0.97, 0.86)
        case .goldenrod: (0.98, 0.9, 0.68)
        case .buff: (0.96, 0.92, 0.82)
        case .salmon: (1, 0.86, 0.8)
        case .cherry: (0.98, 0.78, 0.82)
        }
    }

    public init?(reading text: String) {
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == text.lowercased() }) else { return nil }
        self = match
    }
}

/// A scene's number as locked: kept so a cut scene can still print as OMITTED.
public struct LockedScene: Sendable, Equatable {
    public var id: String
    public var number: String
    public var heading: String

    public init(id: String, number: String, heading: String) {
        self.id = id
        self.number = number
        self.heading = heading
    }
}

/// Where a locked page starts: the script line (by scene and element, plus
/// the start of its text to find it again after edits) and, for a page that
/// starts partway through a paragraph or speech, how many printed lines of it
/// came before.
public struct PageAnchor: Sendable, Equatable {
    public var page: String
    /// `s003 action-2`, or `start` for the very top of the script.
    public var at: String
    public var row: Int
    public var text: String

    public init(page: String, at: String, row: Int = 0, text: String = "") {
        self.page = page
        self.at = at
        self.row = row
        self.text = text
    }
}

/// One revision: its colour and the date it was started. Its baseline (the
/// script as it was when the revision started) is in `script/revisions/`.
public struct ScriptRevision: Sendable, Equatable {
    public var color: RevisionColor
    public var date: String

    public init(color: RevisionColor, date: String) {
        self.color = color
        self.date = date
    }
}

/// `script/production.json`: locked scene numbers, locked pages and revisions.
///
/// ```json
/// {
///   "scenes": [{"id": "s001", "number": "1", "heading": "EXT. HARBOUR - DAWN"}],
///   "pages": [{"page": "1", "at": "start"}, {"page": "2", "at": "s002 action-3", "text": "She stops"}],
///   "revisions": [{"color": "Blue", "date": "2026-11-23"}]
/// }
/// ```
/// Read and written like the other JSON files: key order and unknown keys are kept.
public struct ProductionFile: TextBackedFile {
    public static let path = "script/production.json"
    public static let revisionsFolder = "script/revisions"

    public var root: JSONObject

    public init() { root = JSONObject() }

    public init(root: JSONObject) { self.root = root }

    public init(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.init()
            return
        }
        guard case .object(let root) = try OrderedJSON.parse(text) else {
            throw OrderedJSON.ParseError(message: "production.json must be a JSON object", offset: 0)
        }
        self.init(root: root)
    }

    public var text: String { OrderedJSON.object(root).pretty() + "\n" }

    // MARK: Scenes

    /// Locked scene numbers, in script order at lock time; nil when not locked.
    public var scenes: [LockedScene]? {
        get {
            guard let items = root["scenes"]?.array else { return nil }
            return items.compactMap(\.object).compactMap { object in
                guard let id = object.text("id"), let number = object.text("number") else { return nil }
                return LockedScene(id: id, number: number, heading: object.text("heading") ?? "")
            }
        }
        set {
            root["scenes"] = newValue.map { list in
                .array(list.map { .object(JSONObject([("id", .string($0.id)), ("number", .string($0.number)), ("heading", .string($0.heading))])) })
            }
        }
    }

    public var scenesLocked: Bool { scenes != nil }

    // MARK: Pages

    /// Where each locked page starts; nil when pages aren't locked.
    public var pages: [PageAnchor]? {
        get {
            guard let items = root["pages"]?.array else { return nil }
            return items.compactMap(\.object).compactMap { object in
                guard let page = object.text("page"), let at = object.text("at") else { return nil }
                return PageAnchor(page: page, at: at, row: Int(object["row"]?.double ?? 0), text: object.text("text") ?? "")
            }
        }
        set {
            root["pages"] = newValue.map { list in
                .array(list.map { anchor in
                    var object = JSONObject([("page", .string(anchor.page)), ("at", .string(anchor.at))])
                    if anchor.row > 0 { object["row"] = .number(Double(anchor.row)) }
                    if !anchor.text.isEmpty { object["text"] = .string(anchor.text) }
                    return .object(object)
                })
            }
        }
    }

    public var pagesLocked: Bool { pages != nil }

    // MARK: Revisions

    public var revisions: [ScriptRevision] {
        get {
            (root["revisions"]?.array ?? []).compactMap(\.object).compactMap { object in
                guard let color = object.text("color").flatMap(RevisionColor.init(reading:)) else { return nil }
                return ScriptRevision(color: color, date: object.text("date") ?? "")
            }
        }
        set {
            root["revisions"] = newValue.isEmpty ? nil : .array(newValue.map {
                .object(JSONObject([("color", .string($0.color.rawValue)), ("date", .string($0.date))]))
            })
        }
    }

    /// The revision being worked on: changes since its baseline are marked.
    public var currentRevision: ScriptRevision? { revisions.last }

    /// The colour the next revision gets: Blue after the (white) locked draft.
    public var nextColor: RevisionColor { revisions.last?.color.next ?? .blue }

    /// `script/revisions/01 blue` for the first revision.
    public static func baselineFolder(index: Int, color: RevisionColor) -> String {
        revisionsFolder + "/" + String(format: "%02d", index + 1) + " " + color.rawValue.lowercased()
    }

    public var currentBaselineFolder: String? {
        guard let revision = currentRevision else { return nil }
        return Self.baselineFolder(index: revisions.count - 1, color: revision.color)
    }

    /// Anything to apply when publishing.
    public var isEmpty: Bool { !scenesLocked && !pagesLocked && revisions.isEmpty }
}
