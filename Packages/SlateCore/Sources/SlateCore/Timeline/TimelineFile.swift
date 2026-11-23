import Foundation

/// A file Slate reads into a value and writes back as text (canvases,
/// timelines, maps). Reading what `text` wrote gives an equal value.
public protocol TextBackedFile: Sendable, Equatable {
    init(text: String) throws
    var text: String { get }
}

extension CanvasFile: TextBackedFile {}

// MARK: - Shared helpers for JSON records

extension JSONObject {
    /// A string value; empty strings count as missing.
    func text(_ key: String) -> String? {
        guard let value = self[key]?.string, !value.isEmpty else { return nil }
        return value
    }

    /// Sets a string, removing the key for nil or "".
    mutating func setText(_ key: String, _ value: String?) {
        self[key] = value.flatMap { $0.isEmpty ? nil : .string($0) }
    }

    /// A list of strings (a lone string counts as a list of one).
    func strings(_ key: String) -> [String] {
        switch self[key] {
        case .array(let items): items.compactMap(\.string)
        case .string(let value): value.isEmpty ? [] : [value]
        default: []
        }
    }

    /// Sets a list of strings, removing the key when empty.
    mutating func setStrings(_ key: String, _ values: [String]) {
        self[key] = values.isEmpty ? nil : .array(values.map(OrderedJSON.string))
    }
}

/// A short random ID with a prefix (`e-3f2a`) not already in `used`.
func shortID(_ prefix: String, used: Set<String>) -> String {
    var length = 4
    while true {
        for _ in 0..<64 {
            let id = prefix + "-" + (0..<length).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
            if !used.contains(id) { return id }
        }
        length += 1
    }
}

// MARK: - Timeline records

/// A lane: one character or story thread.
public struct TimelineLane: Sendable, Equatable, Identifiable {
    public var object: JSONObject

    public init(object: JSONObject) { self.object = object }

    public init(id: String, name: String, note: String? = nil) {
        object = JSONObject([("id", .string(id)), ("name", .string(name))])
        if let note { object.setText("note", note) }
    }

    public var id: String { object.text("id") ?? "" }

    public var name: String {
        get { object.text("name") ?? id }
        set { object.setText("name", newValue) }
    }

    /// The note this lane follows: a note `id`, a path, or a name.
    public var note: String? {
        get { object.text("note") }
        set { object.setText("note", newValue) }
    }

    public var color: String? {
        get { object.text("color") }
        set { object.setText("color", newValue) }
    }
}

/// An alternate timeline. It forks from an event and can rejoin at another.
public struct TimelineBranch: Sendable, Equatable, Identifiable {
    public var object: JSONObject

    public init(object: JSONObject) { self.object = object }

    public init(id: String, name: String? = nil, forksFrom: String? = nil) {
        object = JSONObject([("id", .string(id))])
        object.setText("name", name)
        object.setText("forksFrom", forksFrom)
    }

    public var id: String { object.text("id") ?? "" }

    public var name: String {
        get { object.text("name") ?? id }
        set { object.setText("name", newValue == id ? nil : newValue) }
    }

    public var forksFrom: String? {
        get { object.text("forksFrom") }
        set { object.setText("forksFrom", newValue) }
    }

    public var rejoins: String? {
        get { object.text("rejoins") }
        set { object.setText("rejoins", newValue) }
    }

    public var color: String? {
        get { object.text("color") }
        set { object.setText("color", newValue) }
    }
}

/// Something that happens in the story's world.
public struct TimelineEvent: Sendable, Equatable, Identifiable {
    public var object: JSONObject

    public init(object: JSONObject) { self.object = object }

    public init(id: String, title: String, world: String, lane: String?, branch: String? = nil) {
        object = JSONObject([("id", .string(id)), ("title", .string(title)), ("world", .string(world))])
        object.setText("lane", lane)
        object.setText("branch", branch)
    }

    public var id: String { object.text("id") ?? "" }

    public var title: String {
        get { object.text("title") ?? "Untitled event" }
        set { object.setText("title", newValue) }
    }

    /// When it happens in the world, in the timeline's units.
    public var world: String {
        get { object.text("world") ?? "" }
        set { object.setText("world", newValue) }
    }

    /// When a span ends; nil for a point event.
    public var end: String? {
        get { object.text("end") }
        set { object.setText("end", newValue) }
    }

    public var lane: String? {
        get { object.text("lane") }
        set { object.setText("lane", newValue) }
    }

    /// nil means the main branch.
    public var branch: String? {
        get { object.text("branch") }
        set { object.setText("branch", newValue) }
    }

    /// Scene IDs (`s014`) that show this event.
    public var scenes: [String] {
        get { object.strings("scenes") }
        set { object.setStrings("scenes", newValue) }
    }

    /// Where it happens: a note `id`, a path, or a name (`The Station`).
    public var location: String? {
        get { object.text("location") }
        set { object.setText("location", newValue) }
    }

    /// Events that cause this one, so must come before it on everyone's line.
    public var after: [String] {
        get { object.strings("after") }
        set { object.setStrings("after", newValue) }
    }

    public var summary: String? {
        get { object.text("summary") }
        set { object.setText("summary", newValue) }
    }

    public var color: String? {
        get { object.text("color") }
        set { object.setText("color", newValue) }
    }
}

/// A time-travel link: the traveller leaves at `from` and arrives at `to`.
public struct TimelineJump: Sendable, Equatable {
    public var object: JSONObject

    public init(object: JSONObject) { self.object = object }

    public init(from: String, to: String, traveller: String) {
        object = JSONObject([("from", .string(from)), ("to", .string(to)), ("traveller", .string(traveller))])
    }

    public var from: String { object.text("from") ?? "" }
    public var to: String { object.text("to") ?? "" }
    /// A lane ID.
    public var traveller: String {
        get { object.text("traveller") ?? "" }
        set { object.setText("traveller", newValue) }
    }

    public var label: String? {
        get { object.text("label") }
        set { object.setText("label", newValue) }
    }
}

// MARK: - The file

/// A `*.timeline.json` file. Keys Slate doesn't know are kept, in order.
public struct TimelineFile: TextBackedFile {
    /// The top-level object; the four lists below are written back into it.
    public var root: JSONObject
    public var lanes: [TimelineLane]
    public var branches: [TimelineBranch]
    public var events: [TimelineEvent]
    public var jumps: [TimelineJump]

    public static let suffix = ".timeline.json"

    public init(units: TimeUnits = .datetime) {
        root = JSONObject([("units", .string(units.rawValue))])
        lanes = []
        branches = []
        events = []
        jumps = []
    }

    public init(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.init()
            return
        }
        guard case .object(let root) = try OrderedJSON.parse(text) else {
            throw OrderedJSON.ParseError(message: "a timeline must be a JSON object", offset: 0)
        }
        self.init(root: root)
    }

    /// Reads the lists out of a parsed top-level object.
    public init(root: JSONObject) {
        func list(_ key: String) -> [JSONObject] { (root[key]?.array ?? []).compactMap(\.object) }
        self.root = root
        lanes = list("lanes").map(TimelineLane.init(object:))
        branches = list("branches").map(TimelineBranch.init(object:))
        events = list("events").map(TimelineEvent.init(object:))
        jumps = list("jumps").map(TimelineJump.init(object:))
    }

    /// The whole object as written: the root with the current lists in place.
    public var composed: JSONObject {
        var object = root
        object["lanes"] = .array(lanes.map { .object($0.object) })
        object["branches"] = .array(branches.map { .object($0.object) })
        object["events"] = .array(events.map { .object($0.object) })
        object["jumps"] = .array(jumps.map { .object($0.object) })
        return object
    }

    public var text: String {
        OrderedJSON.object(composed).pretty() + "\n"
    }

    public static func == (lhs: TimelineFile, rhs: TimelineFile) -> Bool {
        lhs.composed == rhs.composed
    }

    public static var empty: String { TimelineFile().text }

    // MARK: Settings

    public var units: TimeUnits {
        get { root.text("units").flatMap(TimeUnits.init(rawValue:)) ?? .datetime }
        set { root["units"] = .string(newValue.rawValue) }
    }

    /// Era names for custom calendars, oldest first.
    public var eras: [String] {
        get { root["calendar"]?.object?.strings("eras") ?? [] }
        set {
            var calendar = root["calendar"]?.object ?? JSONObject()
            calendar.setStrings("eras", newValue)
            root["calendar"] = calendar.pairs.isEmpty ? nil : .object(calendar)
        }
    }

    public var scale: TimeScale { TimeScale(units: units, eras: eras) }

    // MARK: Lookup

    /// The branch events without a `branch` belong to.
    public var mainBranch: String { branches.first?.id ?? "prime" }

    public func branch(of event: TimelineEvent) -> String { event.branch ?? mainBranch }

    public func event(_ id: String) -> TimelineEvent? { events.first { $0.id == id } }
    public func lane(_ id: String) -> TimelineLane? { lanes.first { $0.id == id } }
    public func branchNamed(_ id: String) -> TimelineBranch? { branches.first { $0.id == id } }
    public func eventIndex(_ id: String) -> Int? { events.firstIndex { $0.id == id } }

    var usedIDs: Set<String> {
        Set(events.map(\.id) + lanes.map(\.id) + branches.map(\.id))
    }
}
