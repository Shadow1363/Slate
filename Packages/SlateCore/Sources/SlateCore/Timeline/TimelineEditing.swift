import Foundation

/// Edits on a timeline, as pure functions of `TimelineFile`.
public enum TimelineEditing {
    public static func newEventID(in file: TimelineFile) -> String { shortID("e", used: file.usedIDs) }
    public static func newBranchID(in file: TimelineFile) -> String { shortID("b", used: file.usedIDs) }

    /// A lane ID from its name (`Mara Voss` → `mara-voss`), numbered if taken.
    public static func newLaneID(_ name: String, in file: TimelineFile) -> String {
        let base = Slug.make(name).isEmpty ? "lane" : Slug.make(name)
        var id = base
        var counter = 2
        while file.usedIDs.contains(id) {
            id = "\(base)-\(counter)"
            counter += 1
        }
        return id
    }

    // MARK: Events

    public static func adding(_ event: TimelineEvent, to file: TimelineFile) -> TimelineFile {
        var copy = file
        copy.events.append(event)
        return copy
    }

    public static func updating(_ id: String, in file: TimelineFile, _ change: (inout TimelineEvent) -> Void) -> TimelineFile {
        guard let index = file.eventIndex(id) else { return file }
        var copy = file
        change(&copy.events[index])
        return copy
    }

    /// Removes events, the jumps that touch them, and references to them.
    public static func removingEvents(_ ids: Set<String>, from file: TimelineFile) -> TimelineFile {
        var copy = file
        copy.events.removeAll { ids.contains($0.id) }
        copy.jumps.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        for index in copy.events.indices where copy.events[index].after.contains(where: ids.contains) {
            copy.events[index].after.removeAll { ids.contains($0) }
        }
        for index in copy.branches.indices {
            if let fork = copy.branches[index].forksFrom, ids.contains(fork) { copy.branches[index].forksFrom = nil }
            if let rejoin = copy.branches[index].rejoins, ids.contains(rejoin) { copy.branches[index].rejoins = nil }
        }
        return copy
    }

    // MARK: Lanes

    public static func addingLane(_ lane: TimelineLane, to file: TimelineFile) -> TimelineFile {
        var copy = file
        copy.lanes.append(lane)
        return copy
    }

    public static func updatingLane(_ id: String, in file: TimelineFile, _ change: (inout TimelineLane) -> Void) -> TimelineFile {
        guard let index = file.lanes.firstIndex(where: { $0.id == id }) else { return file }
        var copy = file
        change(&copy.lanes[index])
        return copy
    }

    /// Removes a lane. Its events stay, with no lane; its jumps go.
    public static func removingLane(_ id: String, from file: TimelineFile) -> TimelineFile {
        var copy = file
        copy.lanes.removeAll { $0.id == id }
        copy.jumps.removeAll { $0.traveller == id }
        for index in copy.events.indices where copy.events[index].lane == id {
            copy.events[index].lane = nil
        }
        return copy
    }

    public static func movingLane(_ id: String, by offset: Int, in file: TimelineFile) -> TimelineFile {
        guard let index = file.lanes.firstIndex(where: { $0.id == id }) else { return file }
        let target = min(max(index + offset, 0), file.lanes.count - 1)
        guard target != index else { return file }
        var copy = file
        copy.lanes.swapAt(index, target)
        return copy
    }

    // MARK: Branches

    /// Adds a branch forking from an event. A timeline with no branches first
    /// gets `prime`, so events without a branch stay on the main line.
    public static func addingBranch(_ name: String, forksFrom event: String?, to file: TimelineFile) -> (TimelineFile, String) {
        var copy = file
        if copy.branches.isEmpty { copy.branches.append(TimelineBranch(id: "prime")) }
        let id = newBranchID(in: copy)
        copy.branches.append(TimelineBranch(id: id, name: name, forksFrom: event))
        return (copy, id)
    }

    public static func updatingBranch(_ id: String, in file: TimelineFile, _ change: (inout TimelineBranch) -> Void) -> TimelineFile {
        guard let index = file.branches.firstIndex(where: { $0.id == id }) else { return file }
        var copy = file
        change(&copy.branches[index])
        return copy
    }

    /// Removes a branch; its events move to the main branch.
    public static func removingBranch(_ id: String, from file: TimelineFile) -> TimelineFile {
        guard id != file.mainBranch else { return file }
        var copy = file
        copy.branches.removeAll { $0.id == id }
        for index in copy.events.indices where copy.events[index].branch == id {
            copy.events[index].branch = nil
        }
        return copy
    }

    // MARK: Jumps

    public static func addingJump(from: String, to: String, traveller: String, in file: TimelineFile) -> TimelineFile {
        guard from != to, !file.jumps.contains(where: { $0.from == from && $0.to == to && $0.traveller == traveller }) else { return file }
        var copy = file
        copy.jumps.append(TimelineJump(from: from, to: to, traveller: traveller))
        return copy
    }

    public static func removingJump(at index: Int, from file: TimelineFile) -> TimelineFile {
        guard file.jumps.indices.contains(index) else { return file }
        var copy = file
        copy.jumps.remove(at: index)
        return copy
    }
}
