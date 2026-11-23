import Foundation
import Testing
@testable import SlateCore

@Suite("Timeline")
struct TimelineTests {
    static let path = "universe/timelines/main.timeline.json"

    static func sample() throws -> String {
        try String(contentsOf: Fixtures.sampleProject.appending(path: path), encoding: .utf8)
    }

    static func analysis() throws -> TimelineAnalysis {
        TimelineAnalysis(file: try TimelineFile(text: sample()), sceneOrder: ["s014": 1])
    }

    // MARK: File

    @Test func readsTheSample() throws {
        let file = try TimelineFile(text: Self.sample())
        #expect(file.units == .datetime)
        #expect(file.lanes.map(\.id) == ["mara", "thomas"])
        #expect(file.lanes[0].note == "c-7f3a")
        #expect(file.mainBranch == "prime")
        #expect(file.branches[1].forksFrom == "e-07")
        #expect(file.events.count == 7)
        #expect(file.event("e-05")?.end == "2031-02-28")
        #expect(file.event("e-07")?.scenes == ["s014"])
        #expect(file.event("e-13")?.after == ["e-12"])
        #expect(file.jumps.first?.traveller == "mara")
        #expect(file.branch(of: file.event("e-01")!) == "prime")
    }

    @Test func unchangedFilesRoundTripByteForByte() throws {
        let text = try Self.sample()
        #expect(try TimelineFile(text: text).text == text)
        #expect(try TimelineFile(text: TimelineFile.empty).text == TimelineFile.empty)
        #expect(try TimelineFile(text: "") == TimelineFile())
    }

    @Test func unknownKeysSurviveEdits() throws {
        var file = try TimelineFile(text: Self.sample())
        file = TimelineEditing.updating("e-01", in: file) { $0.title = "First shift" }
        let text = file.text
        #expect(text.contains("\"studio\": {\"note\": \"Unknown keys like this one must survive a save.\"}"))
        #expect(text.contains("\"title\": \"First shift\""))
        // Other apps' key order is kept.
        let other = try TimelineFile(text: #"{"events":[{"world":"Day 2","id":"x","custom":true}],"units":"days"}"#)
        #expect(other.text.hasPrefix("{\n  \"events\": [\n    {\"world\": \"Day 2\", \"id\": \"x\", \"custom\": true}\n  ],\n  \"units\": \"days\""))
        #expect(throws: (any Error).self) { try TimelineFile(text: "[1, 2]") }
    }

    // MARK: Time

    @Test func readsDates() {
        let scale = TimeScale(units: .datetime)
        let keys = ["1998", "1998-06", "1998-06-02", "1998-06-02T09:00", "2031-03-14 22:10:30"].map { scale.key($0) }
        #expect(keys.allSatisfy { $0 != nil })
        #expect(keys.compactMap { $0 } == keys.compactMap { $0 }.sorted())
        #expect(scale.key("1970-01-01") == 0)
        #expect(scale.key("1970-01-02T00:01") == 86_460)
        #expect(scale.key("-500")! < scale.key("1")!)
        #expect(scale.key("2031-13-01") == nil)
        #expect(scale.key("soon") == nil)
        #expect(scale.label("2031-03-14T22:10") == "14 Mar 2031, 22:10")
        #expect(scale.label("1998") == "1998")
        #expect(scale.label("-500") == "500 BC")
    }

    @Test func readsDaysAndEras() {
        let days = TimeScale(units: .days)
        #expect(days.key("Day 3") == Double(3 * 86_400))
        #expect(days.key("day 3, 14:00") == Double(3 * 86_400 + 14 * 3600))
        #expect(days.key("-2")! < days.key("Day 0")!)
        #expect(days.label("3 9:05") == "Day 3, 09:05")
        let eras = TimeScale(units: .custom, eras: ["First Age", "Second Age"])
        #expect(eras.key("First Age 900")! < eras.key("Second Age 1")!)
        #expect(eras.key("second age 12") != nil)
        #expect(eras.key("Third Age 1") == nil)
        #expect(TimeScale(units: .custom).key("312") == 312)
    }

    // MARK: Orders

    @Test func worldAndStoryOrder() throws {
        let analysis = try Self.analysis()
        #expect(analysis.worldOrder.map(\.id) == ["e-12", "e-13", "e-01", "e-05", "e-07", "e-08", "e-21"])
        #expect(analysis.storyOrder.map(\.id) == ["e-07"])
        #expect(analysis.offScreen.count == 6)
    }

    @Test func livedLineFollowsJumps() throws {
        let line = try Self.analysis().lived(by: "mara")
        #expect(line.entries.map(\.event.id) == ["e-01", "e-08", "e-21", "e-07", "e-12", "e-13"])
        #expect(line.entries.map(\.stint) == [0, 0, 0, 0, 1, 1])
        #expect(line.unplaced.isEmpty)
    }

    @Test func causesMoveEventsIntoLaterStints() throws {
        var file = try TimelineFile(text: Self.sample())
        // Without `after`, a 1998 night is ambiguous and goes to the first stint.
        file = TimelineEditing.updating("e-13", in: file) { $0.after = [] }
        #expect(TimelineAnalysis(file: file).lived(by: "mara").stint(of: "e-13") == 0)
    }

    @Test func forwardJumpsLeaveGaps() throws {
        var file = TimelineFile(units: .days)
        file.lanes = [TimelineLane(id: "kai", name: "Kai")]
        file.events = [
            TimelineEvent(id: "a", title: "Leaves", world: "Day 1", lane: "kai"),
            TimelineEvent(id: "b", title: "Arrives", world: "Day 10", lane: "kai"),
            TimelineEvent(id: "c", title: "Day five", world: "Day 5", lane: "kai"),
        ]
        file.jumps = [TimelineJump(from: "a", to: "b", traveller: "kai")]
        let analysis = TimelineAnalysis(file: file)
        #expect(analysis.lived(by: "kai").unplaced.map(\.id) == ["c"])
        #expect(analysis.warnings().map(\.kind) == [.unplaced])
    }

    // MARK: Continuity

    @Test func sampleWarnings() throws {
        let warnings = try Self.analysis().warnings()
        #expect(warnings.map(\.kind) == [.reference, .twoPlaces])
        #expect(warnings[0].message.contains("s003"))
        #expect(warnings[1].events == ["e-08", "e-07"])
        #expect(warnings[1].message.hasPrefix("Mara is in two places at 14 Mar 2031, 22:10"))
    }

    @Test func samePlaceSilencesTheWarning() throws {
        let warnings = try Self.analysis().warnings { _, _ in true }
        #expect(!warnings.contains { $0.kind == .twoPlaces })
    }

    @Test func causesOutOfOrder() throws {
        var file = try TimelineFile(text: Self.sample())
        // The first night shift can't be caused by something years later on the same stint.
        file = TimelineEditing.updating("e-01", in: file) { $0.after = ["e-08"] }
        let warnings = TimelineAnalysis(file: file).warnings()
        #expect(warnings.contains { $0.kind == .cause && $0.events == ["e-01", "e-08"] })
        // With no shared line, world time decides.
        var plain = TimelineFile()
        plain.events = [
            TimelineEvent(id: "x", title: "Effect", world: "2000", lane: nil),
            TimelineEvent(id: "y", title: "Cause", world: "2001", lane: nil),
        ]
        plain.events[0].after = ["y"]
        #expect(TimelineAnalysis(file: plain).warnings().map(\.kind) == [.cause])
    }

    @Test func badTimesAndReferences() {
        var file = TimelineFile(units: .days)
        file.events = [
            TimelineEvent(id: "a", title: "A", world: "someday", lane: "ghost"),
            TimelineEvent(id: "b", title: "B", world: "Day 4", lane: nil, branch: "nope"),
        ]
        file.events[1].end = "Day 2"
        file.jumps = [TimelineJump(from: "a", to: "zz", traveller: "ghost")]
        let kinds = TimelineAnalysis(file: file).warnings().map(\.kind)
        #expect(kinds == [.time, .reference, .time, .reference, .reference, .reference])
    }

    // MARK: Layout

    @Test func worldLayout() throws {
        let layout = TimelineLayout.make(try Self.analysis(), mode: .world)
        #expect(layout.columns.count == 6)
        #expect(layout.columns.last?.label == "14 Mar 2031, 22:10")
        #expect(layout.rows.map(\.id) == ["mara|prime", "mara|b2", "thomas|prime"])
        #expect(layout.rows[1].title == "Mara · No fire")
        let winter = try #require(layout.item(for: "e-05"))
        #expect((winter.column, winter.endColumn, winter.row) == (3, 4, 2))
        #expect(layout.slots == [2, 1, 1])
        #expect(layout.item(for: "e-08")?.slot == 1)
    }

    @Test func storyAndPersonalLayouts() throws {
        let analysis = try Self.analysis()
        let story = TimelineLayout.make(analysis, mode: .story, scenes: [("s014", "INT. KITCHEN - NIGHT")])
        #expect(story.columns.map(\.label) == ["Scene 1", "Not in the script"])
        #expect(story.item(for: "e-07")?.column == 0)
        #expect(story.item(for: "e-01")?.column == 1)
        let personal = TimelineLayout.make(analysis, mode: .personal, traveller: "mara")
        #expect(personal.rows.count == 1)
        #expect(personal.columns.count == 6)
        #expect(personal.columns[4].detail == "After jump 1")
        #expect(personal.items.map(\.column) == [0, 1, 2, 3, 4, 5])
    }

    @Test func noLaneRows() {
        var file = TimelineFile(units: .days)
        file.events = [TimelineEvent(id: "a", title: "A", world: "Day 1", lane: nil), TimelineEvent(id: "b", title: "B", world: "", lane: nil)]
        let layout = TimelineLayout.make(TimelineAnalysis(file: file), mode: .world)
        #expect(layout.rows.map(\.title) == ["No lane"])
        #expect(layout.columns.map(\.label) == ["Day 1", "No time"])
        #expect(layout.item(for: "b")?.column == 1)
    }

    // MARK: Editing

    @Test func removingAnEventCleansUp() throws {
        let file = try TimelineFile(text: Self.sample())
        let removed = TimelineEditing.removingEvents(["e-12", "e-07"], from: file)
        #expect(removed.jumps.isEmpty)
        #expect(removed.event("e-13")?.after == [])
        #expect(removed.event("e-13")?.object["after"] == nil)
        #expect(removed.branches[1].forksFrom == nil)
    }

    @Test func lanesBranchesAndJumps() {
        var file = TimelineFile(units: .days)
        let id = TimelineEditing.newLaneID("Mara Voss", in: file)
        #expect(id == "mara-voss")
        file = TimelineEditing.addingLane(TimelineLane(id: id, name: "Mara Voss"), to: file)
        #expect(TimelineEditing.newLaneID("Mara Voss", in: file) == "mara-voss-2")
        let eventID = TimelineEditing.newEventID(in: file)
        #expect(eventID.hasPrefix("e-") && eventID.count == 6)
        file = TimelineEditing.adding(TimelineEvent(id: eventID, title: "Fire", world: "Day 1", lane: id), to: file)
        let (branched, branch) = TimelineEditing.addingBranch("What if", forksFrom: eventID, to: file)
        #expect(branched.branches.map(\.id) == ["prime", branch])
        #expect(TimelineEditing.removingBranch("prime", from: branched) == branched)
        file = TimelineEditing.addingJump(from: eventID, to: eventID, traveller: id, in: branched)
        #expect(file.jumps.isEmpty)
        file = TimelineEditing.removingLane(id, from: file)
        #expect(file.events[0].lane == nil)
    }

    // MARK: Links

    @Test func lanesAndLocationsAreBacklinks() throws {
        let file = IndexedFile.index(path: Self.path, text: try Self.sample())
        #expect(file.links.allSatisfy { $0.kind == .timeline })
        let graph = LinkGraph(files: [
            file,
            IndexedFile.index(path: "universe/characters/mara-voss.md", text: "---\nid: c-7f3a\nname: Mara Voss\n---\n"),
            IndexedFile.index(path: "universe/characters/thomas-wiley-cade.md", text: "---\ntitle: Thomas Wiley Cade\n---\n"),
            IndexedFile.index(path: "universe/locations/the-station.md", text: "---\nid: l-51c0\nname: The Station\n---\n"),
        ])
        #expect(graph.backlinks(to: "universe/characters/mara-voss.md").map(\.snippet) == ["“Mara” on this timeline"])
        #expect(graph.backlinks(to: "universe/characters/thomas-wiley-cade.md").count == 1)
        #expect(graph.backlinks(to: "universe/locations/the-station.md").count == 3)
        #expect(graph.resolve("c-7f3a")?.via == .id)
        // "The Archive" has no note.
        #expect(graph.unresolved(in: Self.path).map(\.link.target) == ["The Archive"])
    }

    @MainActor
    @Test func renameFollowsPathsButNotIDs() throws {
        let folder = try TempFolder()
        let root = try Fixtures.copySampleProject(into: folder)
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        let index = LinkIndex(store: store)
        let paths = Set(store.files.values.flatMap { $0 }.map(\.relativePath))
        let thomas = try #require(RenameRefactor.plan(renaming: "universe/characters/thomas-wiley-cade.md", to: "Tom Cade",
                                                      in: index.graph, existingPaths: paths))
        #expect(thomas.edits.contains { $0.path == Self.path && $0.replacement == "universe/characters/tom-cade.md" })
        let mara = try #require(RenameRefactor.plan(renaming: "universe/characters/mara-voss.md", to: "Mara Kell",
                                                    in: index.graph, existingPaths: paths))
        #expect(!mara.edits.contains { $0.path == Self.path })
        try RenameRefactor.apply(thomas, updateLinks: true, store: store)
        let file = try TimelineFile(text: folder.read("SampleProject/" + Self.path))
        #expect(file.lane("thomas")?.note == "universe/characters/tom-cade.md")
    }
}
