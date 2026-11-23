import Foundation

/// A continuity problem on a timeline.
public struct TimelineWarning: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        /// A world time that can't be read in the timeline's units.
        case time
        /// An ID that points at nothing (lane, branch, event, scene).
        case reference
        /// A character in two places at once without a jump.
        case twoPlaces
        /// An event that comes before its cause on someone's line.
        case cause
        /// An event that falls between a traveller's jumps.
        case unplaced
    }

    public let kind: Kind
    public let message: String
    /// Events involved, for selecting them.
    public let events: [String]

    public var id: String { kind.rawValue + ":" + events.joined(separator: ",") + ":" + message }
}

/// Orders and checks a timeline: world order, story order (from the
/// script's scene order) and each traveller's lived line.
public struct TimelineAnalysis: Sendable {
    public let file: TimelineFile
    /// Scene ID → position in the script (1-based). Empty when there's no script.
    public let sceneOrder: [String: Int]
    private let starts: [String: Double]
    private let ends: [String: Double]
    private let fileIndex: [String: Int]

    public init(file: TimelineFile, sceneOrder: [String: Int] = [:]) {
        self.file = file
        self.sceneOrder = sceneOrder
        let scale = file.scale
        var starts: [String: Double] = [:]
        var ends: [String: Double] = [:]
        var fileIndex: [String: Int] = [:]
        for (index, event) in file.events.enumerated() {
            if fileIndex[event.id] == nil { fileIndex[event.id] = index }
            if let key = scale.key(event.world) { starts[event.id] = key }
            if let end = event.end, let key = scale.key(end) { ends[event.id] = key }
        }
        self.starts = starts
        self.ends = ends
        self.fileIndex = fileIndex
    }

    /// The event's start as a sort key, or nil if its time can't be read.
    public func start(_ id: String) -> Double? { starts[id] }

    /// The event's end (its start for a point event).
    public func end(_ id: String) -> Double? {
        guard let start = starts[id] else { return nil }
        return max(ends[id] ?? start, start)
    }

    // MARK: - World order

    /// Chronological; events whose time can't be read go last, in file order.
    public var worldOrder: [TimelineEvent] {
        file.events.sorted { a, b in
            switch (starts[a.id], starts[b.id]) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (fileIndex[a.id] ?? 0) < (fileIndex[b.id] ?? 0)
            }
        }
    }

    // MARK: - Story order

    /// The event's first scene that exists in the script.
    public func firstScene(of event: TimelineEvent) -> Int? {
        event.scenes.compactMap { sceneOrder[$0] }.min()
    }

    /// Events as the film shows them, by their first scene.
    public var storyOrder: [TimelineEvent] {
        file.events.compactMap { event in firstScene(of: event).map { (event, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : (starts[$0.0.id] ?? 0) < (starts[$1.0.id] ?? 0) }
            .map(\.0)
    }

    /// Events no scene in the script shows.
    public var offScreen: [TimelineEvent] {
        file.events.filter { firstScene(of: $0) == nil }
    }

    // MARK: - Lived lines

    /// One traveller's lived experience. Their jumps, in file order, cut it
    /// into stints: before the first jump, between each arrival and the next
    /// departure, and after the last arrival.
    public struct LivedLine: Sendable, Equatable {
        public struct Entry: Sendable, Equatable {
            public let event: TimelineEvent
            /// 0 before the first jump, 1 after it, and so on.
            public let stint: Int
        }

        public let traveller: String
        public let entries: [Entry]
        /// The traveller's events that fit no stint (between jumps, or with no readable time).
        public let unplaced: [TimelineEvent]

        public func position(of id: String) -> Int? {
            entries.firstIndex { $0.event.id == id }
        }

        public func stint(of id: String) -> Int? {
            entries.first { $0.event.id == id }?.stint
        }
    }

    /// The traveller's jumps whose ends both exist, in the order they're lived.
    public func jumps(of traveller: String) -> [TimelineJump] {
        file.jumps.filter { $0.traveller == traveller && file.event($0.from) != nil && file.event($0.to) != nil }
    }

    public func lived(by traveller: String) -> LivedLine {
        let jumps = jumps(of: traveller)
        let stintCount = jumps.count + 1
        // The world-time window of each stint.
        let bounds: [(lower: Double, upper: Double)] = (0..<stintCount).map { k in
            let lower = k == 0 ? -Double.infinity : (starts[jumps[k - 1].to] ?? -Double.infinity)
            let upper = k == jumps.count ? Double.infinity : (starts[jumps[k].from] ?? Double.infinity)
            return (lower, upper)
        }
        // Jump ends are fixed: a departure closes stint k, an arrival opens k + 1.
        var fixed: [String: Int] = [:]
        var rank: [String: Int] = [:]
        for (k, jump) in jumps.enumerated() {
            if fixed[jump.from] == nil { fixed[jump.from] = k; rank[jump.from] = 2 }
            if fixed[jump.to] == nil { fixed[jump.to] = k + 1; rank[jump.to] = 0 }
        }
        let members = worldOrder.filter { $0.lane == traveller || fixed[$0.id] != nil }
        let memberIDs = Set(members.map(\.id))

        var stint: [String: Int] = fixed
        var unplaced: Set<String> = []
        func candidates(_ id: String) -> [Int] {
            guard let key = starts[id] else { return [] }
            return (0..<stintCount).filter { bounds[$0].lower <= key && key <= bounds[$0].upper }
        }
        // Causes push an event into a later stint; a few passes settle chains.
        for _ in 0..<3 {
            for event in members where fixed[event.id] == nil {
                let options = candidates(event.id)
                guard !options.isEmpty else {
                    unplaced.insert(event.id)
                    continue
                }
                let floor = event.after.filter(memberIDs.contains).compactMap { stint[$0] }.max() ?? 0
                stint[event.id] = options.first { $0 >= floor } ?? options.last!
            }
        }
        let entries = members.filter { stint[$0.id] != nil && !unplaced.contains($0.id) }
            .sorted { a, b in
                let sa = stint[a.id]!, sb = stint[b.id]!
                if sa != sb { return sa < sb }
                let ka = starts[a.id] ?? 0, kb = starts[b.id] ?? 0
                if ka != kb { return ka < kb }
                let ra = rank[a.id] ?? 1, rb = rank[b.id] ?? 1
                if ra != rb { return ra < rb }
                return (fileIndex[a.id] ?? 0) < (fileIndex[b.id] ?? 0)
            }
            .map { LivedLine.Entry(event: $0, stint: stint[$0.id]!) }
        return LivedLine(traveller: traveller, entries: entries, unplaced: members.filter { unplaced.contains($0.id) })
    }

    // MARK: - Continuity checks

    /// Every warning, in a stable order.
    /// - Parameter samePlace: Whether two `location` values name the same place
    ///   (the app resolves them through the link index).
    public func warnings(samePlace: (String, String) -> Bool = { LinkGraph.key($0) == LinkGraph.key($1) }) -> [TimelineWarning] {
        var warnings: [TimelineWarning] = []
        let scale = file.scale
        let laneIDs = Set(file.lanes.map(\.id))
        let branchIDs = Set(file.branches.map(\.id))
        func name(_ id: String) -> String { file.event(id)?.title ?? id }
        func laneName(_ id: String) -> String { file.lane(id)?.name ?? id }

        for event in file.events {
            if starts[event.id] == nil {
                let shown = event.world.isEmpty ? "No time is set" : "Can't read the time “\(event.world)”"
                warnings.append(.init(kind: .time, message: "\(shown) for “\(event.title)” (try \(scale.example)).", events: [event.id]))
            }
            if let end = event.end {
                if ends[event.id] == nil {
                    warnings.append(.init(kind: .time, message: "Can't read the end time “\(end)” of “\(event.title)”.", events: [event.id]))
                } else if let start = starts[event.id], ends[event.id]! < start {
                    warnings.append(.init(kind: .time, message: "“\(event.title)” ends before it starts.", events: [event.id]))
                }
            }
            if let lane = event.lane, !laneIDs.contains(lane) {
                warnings.append(.init(kind: .reference, message: "“\(event.title)” is on a lane that doesn't exist (\(lane)).", events: [event.id]))
            }
            if let branch = event.branch, !branchIDs.contains(branch), branch != file.mainBranch {
                warnings.append(.init(kind: .reference, message: "“\(event.title)” is on a branch that doesn't exist (\(branch)).", events: [event.id]))
            }
            for cause in event.after where file.event(cause) == nil {
                warnings.append(.init(kind: .reference, message: "“\(event.title)” follows an event that doesn't exist (\(cause)).", events: [event.id]))
            }
            if !sceneOrder.isEmpty {
                for scene in event.scenes where sceneOrder[scene] == nil {
                    warnings.append(.init(kind: .reference, message: "“\(event.title)” links to scene \(scene), which isn't in the script.", events: [event.id]))
                }
            }
        }
        for jump in file.jumps {
            let ends = [jump.from, jump.to].filter { file.event($0) != nil }
            if ends.count < 2 {
                warnings.append(.init(kind: .reference, message: "A jump by \(laneName(jump.traveller)) points at an event that doesn't exist.", events: ends))
            }
            if !laneIDs.contains(jump.traveller) {
                warnings.append(.init(kind: .reference, message: "A jump's traveller (\(jump.traveller)) isn't a lane.", events: ends))
            }
        }
        for branch in file.branches {
            for (label, id) in [("forks from", branch.forksFrom), ("rejoins at", branch.rejoins)] {
                if let id, file.event(id) == nil {
                    warnings.append(.init(kind: .reference, message: "Branch “\(branch.name)” \(label) an event that doesn't exist (\(id)).", events: []))
                }
            }
        }

        // Lived lines: two places at once, causes out of order, events between jumps.
        var lines: [String: LivedLine] = [:]
        for lane in file.lanes {
            let line = lived(by: lane.id)
            lines[lane.id] = line
            for event in line.unplaced where starts[event.id] != nil {
                warnings.append(.init(kind: .unplaced, message: "“\(event.title)” falls between \(lane.name)'s jumps, when \(lane.name) isn't there.", events: [event.id]))
            }
            var groups: [String: [LivedLine.Entry]] = [:]
            for entry in line.entries {
                groups["\(entry.stint)|\(file.branch(of: entry.event))", default: []].append(entry)
            }
            for key in groups.keys.sorted() {
                let entries = groups[key]!
                for i in entries.indices {
                    for j in entries.indices where j > i {
                        let a = entries[i].event, b = entries[j].event
                        guard let placeA = a.location, let placeB = b.location, !samePlace(placeA, placeB),
                              let a0 = start(a.id), let a1 = end(a.id), let b0 = start(b.id), let b1 = end(b.id),
                              a0 <= b1, b0 <= a1 else { continue }
                        warnings.append(.init(
                            kind: .twoPlaces,
                            message: "\(lane.name) is in two places at \(scale.label(a0 >= b0 ? a.world : b.world)): “\(a.title)” and “\(b.title)”, with no jump between.",
                            events: [a.id, b.id]))
                    }
                }
            }
        }
        for event in file.events {
            for cause in event.after where file.event(cause) != nil {
                let shared = lines.values.filter { $0.position(of: event.id) != nil && $0.position(of: cause) != nil }
                if shared.isEmpty {
                    if let effect = starts[event.id], let reason = starts[cause], reason > effect {
                        warnings.append(.init(kind: .cause, message: "“\(event.title)” happens before its cause “\(name(cause))”.", events: [event.id, cause]))
                    }
                    continue
                }
                for line in shared.sorted(by: { $0.traveller < $1.traveller })
                where line.position(of: cause)! > line.position(of: event.id)! {
                    warnings.append(.init(
                        kind: .cause,
                        message: "On \(laneName(line.traveller))'s line, “\(event.title)” comes before its cause “\(name(cause))”.",
                        events: [event.id, cause]))
                }
            }
        }
        return warnings
    }
}
