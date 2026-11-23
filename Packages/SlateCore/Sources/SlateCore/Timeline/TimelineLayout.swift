import Foundation

/// The three ways to look at one timeline.
public enum TimelineViewMode: String, Sendable, CaseIterable, Identifiable {
    /// Chronological, in world time.
    case world
    /// As the film plays, from scene order.
    case story
    /// One character's lived experience, following their jumps.
    case personal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .world: "World Order"
        case .story: "Story Order"
        case .personal: "Personal"
        }
    }
}

/// Where each event sits on a grid of columns (times or scenes) and rows
/// (lane × branch). Pure data; the view draws it.
public struct TimelineLayout: Sendable, Equatable {
    public struct Column: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let detail: String?
        /// The world time as written, for world-order columns (to add an event there).
        public var world: String? = nil
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        /// nil for events with no (or an unknown) lane.
        public let lane: String?
        public let branch: String
        public let title: String
        public let isMainBranch: Bool
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public let event: String
        public let row: Int
        public let column: Int
        /// The last column a span covers (`column` for a point event).
        public let endColumn: Int
        /// Stacking position inside the row, when items overlap.
        public let slot: Int

        public var id: String { "\(event)@\(column)" }
    }

    public var columns: [Column]
    public var rows: [Row]
    public var items: [Item]
    /// How many items stack in each row.
    public var slots: [Int]

    /// The first item drawn for an event.
    public func item(for event: String) -> Item? {
        items.first { $0.event == event }
    }

    public static let noLane = "—"

    /// Lays out the timeline for a view.
    /// - Parameters:
    ///   - scenes: The script's scenes in order (ID and heading), for story order.
    ///   - traveller: The lane followed in personal view.
    public static func make(_ analysis: TimelineAnalysis, mode: TimelineViewMode, scenes: [(id: String, heading: String)] = [],
                            traveller: String? = nil) -> TimelineLayout {
        switch mode {
        case .world: world(analysis)
        case .story: story(analysis, scenes: scenes)
        case .personal: personal(analysis, traveller: traveller ?? analysis.file.lanes.first?.id ?? "")
        }
    }

    // MARK: World order

    static func world(_ analysis: TimelineAnalysis) -> TimelineLayout {
        let file = analysis.file
        let scale = file.scale
        // One column per distinct time (span ends too), then one for unreadable times.
        var keys: [Double: String] = [:]
        for event in file.events {
            if let key = analysis.start(event.id), keys[key] == nil { keys[key] = event.world }
            if let end = event.end, let key = analysis.end(event.id), keys[key] == nil { keys[key] = end }
        }
        let sorted = keys.keys.sorted()
        var columns = sorted.map { Column(id: "t\($0)", label: scale.label(keys[$0]!), detail: nil, world: keys[$0]!) }
        let index = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0) })
        let unknown = file.events.contains { analysis.start($0.id) == nil }
        if unknown { columns.append(Column(id: "unknown", label: "No time", detail: nil)) }

        let rows = rows(for: file.events, in: file)
        var placed: [(event: String, row: Int, column: Int, end: Int)] = []
        for event in analysis.worldOrder {
            guard let row = rowIndex(event, rows: rows, file: file) else { continue }
            if let start = analysis.start(event.id), let column = index[start] {
                let end = analysis.end(event.id).flatMap { index[$0] } ?? column
                placed.append((event.id, row, column, end))
            } else {
                placed.append((event.id, row, columns.count - 1, columns.count - 1))
            }
        }
        return stacked(columns: columns, rows: rows, placed: placed)
    }

    // MARK: Story order

    static func story(_ analysis: TimelineAnalysis, scenes: [(id: String, heading: String)]) -> TimelineLayout {
        let file = analysis.file
        let shown = Set(file.events.flatMap(\.scenes))
        var columns: [Column] = []
        var sceneColumn: [String: Int] = [:]
        for (number, scene) in scenes.enumerated() where shown.contains(scene.id) && sceneColumn[scene.id] == nil {
            sceneColumn[scene.id] = columns.count
            columns.append(Column(id: "s:" + scene.id, label: "Scene \(number + 1)", detail: scene.heading))
        }
        let offScreen = file.events.filter { $0.scenes.allSatisfy { sceneColumn[$0] == nil } }
        if !offScreen.isEmpty { columns.append(Column(id: "offscreen", label: "Not in the script", detail: nil)) }

        let rows = rows(for: file.events, in: file)
        var placed: [(event: String, row: Int, column: Int, end: Int)] = []
        for event in analysis.worldOrder {
            guard let row = rowIndex(event, rows: rows, file: file) else { continue }
            let columnsShown = Set(event.scenes.compactMap { sceneColumn[$0] }).sorted()
            if columnsShown.isEmpty {
                placed.append((event.id, row, columns.count - 1, columns.count - 1))
            } else {
                for column in columnsShown { placed.append((event.id, row, column, column)) }
            }
        }
        return stacked(columns: columns, rows: rows, placed: placed)
    }

    // MARK: Personal

    static func personal(_ analysis: TimelineAnalysis, traveller: String) -> TimelineLayout {
        let file = analysis.file
        let line = analysis.lived(by: traveller)
        let scale = file.scale
        let name = file.lane(traveller)?.name ?? traveller
        var columns: [Column] = []
        var placed: [(event: String, row: Int, column: Int, end: Int)] = []
        var previousStint = 0
        for entry in line.entries {
            let detail = entry.stint != previousStint ? "After jump \(entry.stint)" : nil
            previousStint = entry.stint
            placed.append((entry.event.id, 0, columns.count, columns.count))
            columns.append(Column(id: "p\(columns.count)", label: scale.label(entry.event.world), detail: detail))
        }
        for event in line.unplaced {
            placed.append((event.id, 0, columns.count, columns.count))
            columns.append(Column(id: "p\(columns.count)", label: scale.label(event.world), detail: "Doesn't fit"))
        }
        let row = Row(id: traveller, lane: traveller, branch: file.mainBranch, title: name, isMainBranch: true)
        return stacked(columns: columns, rows: [row], placed: placed)
    }

    // MARK: Rows and stacking

    /// Lanes in file order, each with its main branch and any branch its events use.
    static func rows(for events: [TimelineEvent], in file: TimelineFile) -> [Row] {
        let laneIDs = Set(file.lanes.map(\.id))
        let branchOrder = [file.mainBranch] + file.branches.map(\.id).filter { $0 != file.mainBranch }
        func branchName(_ id: String) -> String { file.branchNamed(id)?.name ?? id }
        var rows: [Row] = []
        for lane in file.lanes {
            let used = Set(events.filter { $0.lane == lane.id }.map { file.branch(of: $0) })
            for branch in branchOrder + used.subtracting(branchOrder).sorted() where branch == file.mainBranch || used.contains(branch) {
                let isMain = branch == file.mainBranch
                rows.append(Row(id: lane.id + "|" + branch, lane: lane.id, branch: branch,
                                title: isMain ? lane.name : lane.name + " · " + branchName(branch), isMainBranch: isMain))
            }
        }
        let loose = events.filter { $0.lane.map { !laneIDs.contains($0) } ?? true }
        let looseBranches = Set(loose.map { file.branch(of: $0) })
        for branch in branchOrder + looseBranches.subtracting(branchOrder).sorted() where looseBranches.contains(branch) {
            let isMain = branch == file.mainBranch
            rows.append(Row(id: noLane + "|" + branch, lane: nil, branch: branch,
                            title: isMain ? "No lane" : "No lane · " + branchName(branch), isMainBranch: isMain))
        }
        return rows
    }

    static func rowIndex(_ event: TimelineEvent, rows: [Row], file: TimelineFile) -> Int? {
        let lane = event.lane.flatMap { id in file.lane(id) != nil ? id : nil }
        let branch = file.branch(of: event)
        return rows.firstIndex { $0.lane == lane && $0.branch == branch }
    }

    /// Gives overlapping items in a row their own slot (greedy, left to right).
    static func stacked(columns: [Column], rows: [Row], placed: [(event: String, row: Int, column: Int, end: Int)]) -> TimelineLayout {
        var items: [Item] = []
        var slots = Array(repeating: 1, count: rows.count)
        // For each row, the last column each slot is busy until.
        var busy = Array(repeating: [Int](), count: rows.count)
        for entry in placed.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            var slot = busy[entry.row].firstIndex { $0 < entry.column } ?? busy[entry.row].count
            if slot == busy[entry.row].count { busy[entry.row].append(entry.end) } else { busy[entry.row][slot] = entry.end }
            slot = max(slot, 0)
            slots[entry.row] = max(slots[entry.row], slot + 1)
            items.append(Item(event: entry.event, row: entry.row, column: entry.column, endColumn: max(entry.end, entry.column), slot: slot))
        }
        return TimelineLayout(columns: columns, rows: rows, items: items, slots: slots)
    }
}
