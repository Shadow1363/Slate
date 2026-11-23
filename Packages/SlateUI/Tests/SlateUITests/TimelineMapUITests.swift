import AppKit
import Foundation
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Timeline and map models")
struct TimelineMapUITests {
    static let timeline = "universe/timelines/main.timeline.json"
    static let map = "universe/maps/city.map.json"

    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    // MARK: Timeline

    @Test func timelineEditsUndoAndWriteOnce() throws {
        let h = try SessionHarness()
        let document = try h.store.document(at: Self.timeline)
        let original = document.text
        let model = TimelineModel(document: document)
        let undo = undoManager()
        model.file.undoManager = undo
        #expect(model.timeline.events.count == 7)

        undo.beginUndoGrouping()
        model.addEvent(lane: "thomas")
        undo.endUndoGrouping()
        let id = try #require(model.selectedEvent)
        #expect(model.timeline.event(id)?.lane == "thomas")
        // A new event starts at the latest time on the timeline.
        #expect(model.timeline.event(id)?.world == "2031-03-14T22:10")
        #expect(document.text == original)
        model.file.flush()
        #expect(document.text.contains("\"id\": \"\(id)\""))
        // Hand-written keys survive.
        #expect(document.text.contains("\"studio\""))

        undo.undo()
        model.file.flush()
        #expect(document.text == original)
    }

    @Test func jumpsAndBranches() throws {
        let h = try SessionHarness()
        let model = TimelineModel(document: try h.store.document(at: Self.timeline))
        model.pendingJump = "e-01"
        model.completeJump(to: "e-13")
        #expect(model.pendingJump == nil)
        #expect(model.timeline.jumps.last?.from == "e-01")
        #expect(model.timeline.jumps.last?.traveller == "mara")

        model.branch(from: "e-05")
        let event = try #require(model.selectedEvent.flatMap(model.timeline.event))
        #expect(event.branch != nil)
        #expect(model.timeline.branchNamed(event.branch!)?.forksFrom == "e-05")
        #expect(event.lane == "thomas")

        model.select(lane: "thomas")
        model.deleteSelection()
        #expect(model.timeline.lane("thomas") == nil)
        #expect(model.timeline.event("e-05")?.lane == nil)
    }

    @Test func contextUsesTheScriptAndLinks() throws {
        let h = try SessionHarness()
        let model = TimelineModel(document: try h.store.document(at: Self.timeline))
        let context = TimelineContext(session: h.session, model: model)
        #expect(context.scenes.map(\.id) == ["s014"])
        // l-51c0 and "The Station" are the same note, so only the archive clash and s003 are flagged.
        #expect(context.warnings.map(\.kind) == [.reference, .twoPlaces])
        model.mode = .story
        #expect(context.layout.columns.first?.detail == "INT. KITCHEN - NIGHT")
    }

    @Test func outsideTimelineEditsReload() throws {
        let h = try SessionHarness()
        let document = try h.store.document(at: Self.timeline)
        let model = TimelineModel(document: document)
        model.select(event: "e-21")
        var file = model.timeline
        file = TimelineEditing.removingEvents(["e-21"], from: file)
        document.text = file.text
        model.file.documentChanged()
        #expect(model.timeline.events.count == 6)
        #expect(model.selectedEvent == nil)
        // Broken JSON shows an error and keeps the last good timeline.
        document.text = "{ nope"
        model.file.documentChanged()
        #expect(model.file.parseError != nil)
        #expect(model.timeline.events.count == 6)
    }

    // MARK: Map

    @Test func mapPinsRegionsAndUndo() throws {
        let h = try SessionHarness()
        let document = try h.store.document(at: Self.map)
        let model = MapModel(document: document, store: h.store)
        let undo = undoManager()
        model.file.undoManager = undo
        #expect(model.image != nil)
        #expect(model.size == CGSize(width: 600, height: 400))
        model.viewSize = CGSize(width: 1200, height: 800)
        model.fit()

        // A click on the station pin's head selects it.
        let station = model.view(MapPoint(x: 0.42, y: 0.31))
        #expect(model.item(at: CGPoint(x: station.x, y: station.y - 14))?.id == "p-st01")
        // Inside Old Town.
        #expect(model.item(at: model.view(MapPoint(x: 0.2, y: 0.2)))?.id == "r-ot01")
        model.hiddenLayers = ["l1998"]
        #expect(model.item(at: model.view(MapPoint(x: 0.2, y: 0.2))) == nil)

        undo.beginUndoGrouping()
        model.addPin(at: model.view(MapPoint(x: 0.5, y: 0.5)))
        undo.endUndoGrouping()
        #expect(model.map.pins.count == 3)
        #expect(model.map.pins[2].points[0] == MapPoint(x: 0.5, y: 0.5))

        model.tool = .region
        // Two corners aren't a region.
        model.draft = [MapPoint(x: 0.6, y: 0.1), MapPoint(x: 0.8, y: 0.1)]
        model.finishDraft()
        #expect(model.map.regions.count == 1)
        #expect(model.draft.isEmpty)
        model.tool = .region
        model.draft = [MapPoint(x: 0.6, y: 0.1), MapPoint(x: 0.8, y: 0.1), MapPoint(x: 0.7, y: 0.3)]
        model.currentLayer = "l2031"
        undo.beginUndoGrouping()
        model.finishDraft()
        undo.endUndoGrouping()
        #expect(model.map.regions.count == 2)
        #expect(model.map.regions[1].layer == "l2031")
        #expect(model.tool == .select)

        undo.undo()
        #expect(model.map.regions.count == 1)
        undo.undo()
        #expect(model.map.pins.count == 2)
    }

    @Test func showOnMapFindsTheSceneAndItsLocation() throws {
        let h = try SessionHarness()
        let scene = try #require(h.session.script.book.scenes.first)
        // The station pin lists s014.
        #expect(h.session.mapTarget(for: scene) == MapRevealRequest(path: Self.map, item: "p-st01"))
        h.session.showOnMap(scene)
        #expect(h.session.universeSelection == Self.map)
        #expect(h.session.mapReveal?.item == "p-st01")
        #expect(h.session.mapImages == ["universe/maps/city.png"])
        #expect(h.session.timelineFiles == [Self.timeline])
    }

    @Test func newTimelinesAndMapsOpen() throws {
        let h = try SessionHarness()
        h.session.createTimeline()
        #expect(h.session.universeSelection == "universe/timelines/untitled.timeline.json")
        h.session.createMap()
        #expect(h.session.universeSelection == "universe/maps/untitled.map.json")
        let text = try h.store.readText(at: "universe/maps/untitled.map.json")
        #expect(try MapFile(text: text).image == nil)
        h.session.createMap()
        #expect(h.session.universeSelection == "universe/maps/untitled-2.map.json")
    }
}
