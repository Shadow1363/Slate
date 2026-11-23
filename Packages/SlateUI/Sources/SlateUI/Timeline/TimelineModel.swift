import AppKit
import Observation
import SlateCore

/// One open `*.timeline.json`: the file, plus what the view shows.
@MainActor
@Observable
final class TimelineModel {
    let file: FileBackedModel<TimelineFile>

    var mode: TimelineViewMode = .world
    /// The lane followed in personal view.
    var traveller: String?
    var selectedEvent: String?
    var selectedLane: String?
    var selectedBranch: String?
    /// Set while choosing where a jump arrives.
    var pendingJump: String?
    var columnWidth: Double = 150

    static let minColumnWidth = 80.0
    static let maxColumnWidth = 320.0

    init(document: TextDocument) {
        file = FileBackedModel(document: document, empty: TimelineFile())
        file.onReload = { [weak self] fresh in
            guard let self else { return }
            if let id = selectedEvent, fresh.event(id) == nil { selectedEvent = nil }
            if let id = selectedLane, fresh.lane(id) == nil { selectedLane = nil }
            if let id = selectedBranch, fresh.branchNamed(id) == nil { selectedBranch = nil }
        }
    }

    var timeline: TimelineFile { file.value }

    func edit(_ action: String, _ change: (TimelineFile) -> TimelineFile) {
        file.edit(action, change)
    }

    func select(event id: String?) {
        selectedEvent = id
        selectedLane = nil
        selectedBranch = nil
    }

    func select(lane id: String) {
        selectedLane = id
        selectedEvent = nil
        selectedBranch = nil
    }

    func select(branch id: String) {
        selectedBranch = id
        selectedEvent = nil
        selectedLane = nil
    }

    // MARK: Adding

    /// A new event, selected. Its time defaults to the latest one on the timeline.
    func addEvent(lane: String?, branch: String? = nil, world: String? = nil) {
        let file = timeline
        let id = TimelineEditing.newEventID(in: file)
        let analysis = TimelineAnalysis(file: file)
        let time = world ?? analysis.worldOrder.last { analysis.start($0.id) != nil }?.world ?? file.scale.example
        let branchID = branch == file.mainBranch ? nil : branch
        let event = TimelineEvent(id: id, title: "New event", world: time, lane: lane ?? file.lanes.first?.id, branch: branchID)
        edit("Add Event") { TimelineEditing.adding(event, to: $0) }
        select(event: id)
    }

    func addLane(name: String = "New lane", note: String? = nil) {
        let id = TimelineEditing.newLaneID(name, in: timeline)
        edit("Add Lane") { TimelineEditing.addingLane(TimelineLane(id: id, name: name, note: note), to: $0) }
        select(lane: id)
    }

    /// A branch forking from `event`, with a first event on it.
    func branch(from event: String) {
        guard let source = timeline.event(event) else { return }
        let count = timeline.branches.filter { $0.id != timeline.mainBranch }.count
        let (branched, id) = TimelineEditing.addingBranch("Branch \(count + 1)", forksFrom: event, to: timeline)
        let first = TimelineEvent(id: TimelineEditing.newEventID(in: branched), title: "What if…", world: source.world,
                                  lane: source.lane, branch: id)
        file.apply(TimelineEditing.adding(first, to: branched), "Add Branch")
        select(event: first.id)
    }

    /// Finishes a jump started with `pendingJump`.
    func completeJump(to arrival: String) {
        guard let departure = pendingJump else { return }
        pendingJump = nil
        guard departure != arrival, let from = timeline.event(departure) else { return }
        let traveller = from.lane ?? timeline.event(arrival)?.lane ?? timeline.lanes.first?.id ?? ""
        edit("Add Jump") { TimelineEditing.addingJump(from: departure, to: arrival, traveller: traveller, in: $0) }
        select(event: arrival)
    }

    func deleteSelection() {
        if let id = selectedEvent {
            edit("Delete Event") { TimelineEditing.removingEvents([id], from: $0) }
            selectedEvent = nil
        } else if let id = selectedLane {
            edit("Delete Lane") { TimelineEditing.removingLane(id, from: $0) }
            selectedLane = nil
        } else if let id = selectedBranch {
            edit("Delete Branch") { TimelineEditing.removingBranch(id, from: $0) }
            selectedBranch = nil
        }
    }

    func zoom(by factor: Double) {
        columnWidth = min(max(columnWidth * factor, Self.minColumnWidth), Self.maxColumnWidth)
    }
}
