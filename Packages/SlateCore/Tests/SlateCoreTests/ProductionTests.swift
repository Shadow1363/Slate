import Foundation
import Testing
@testable import SlateCore

@Suite("Production")
struct ProductionTests {
    // MARK: Scene numbers

    static func scenes(_ ids: [String]) -> [SceneNumbering.Scene] {
        ids.map { SceneNumbering.Scene(id: $0, heading: "INT. \($0.uppercased()) - DAY") }
    }

    static let locked = (1...5).map { LockedScene(id: "s00\($0)", number: "\($0)", heading: "INT. S00\($0) - DAY") }

    @Test func unlockedNumbersFollowPositionOrFountain() {
        var scenes = Self.scenes(["s001", "s002", "s003"])
        #expect(SceneNumbering.labels(scenes, locked: nil) == ["1", "2", "3"])
        scenes[1].fountainNumber = "2B"
        #expect(SceneNumbering.labels(scenes, locked: nil) == ["1", "2B", "3"])
    }

    @Test func newScenesGetLetters() {
        let labels = SceneNumbering.labels(Self.scenes(["s009", "s001", "s002", "s010", "s011", "s003", "s004", "s005"]), locked: Self.locked)
        #expect(labels == ["A1", "1", "2", "2A", "2B", "3", "4", "5"])
        // A letter already locked is skipped.
        var locked = Self.locked
        locked.insert(LockedScene(id: "s006", number: "2A", heading: ""), at: 2)
        #expect(SceneNumbering.labels(Self.scenes(["s001", "s002", "s006", "s010"]), locked: locked) == ["1", "2", "2A", "2B"])
        #expect(SceneNumbering.lettered(after: "14Z") == "14ZA")
    }

    @Test func cutScenesAreOmittedInPlace() {
        let scenes = Self.scenes(["s001", "s003", "s005"])
        let omitted = SceneNumbering.omitted(scenes, locked: Self.locked)
        #expect(omitted == [OmittedScene(before: 1, number: "2", heading: "INT. S002 - DAY"),
                            OmittedScene(before: 2, number: "4", heading: "INT. S004 - DAY")])
        #expect(SceneNumbering.omitted(Self.scenes(["s001"]), locked: Array(Self.locked.prefix(2))).first?.before == 1)
        // Re-locking keeps omitted scenes, in their place.
        let relocked = SceneNumbering.lock(scenes, existing: Self.locked)
        #expect(relocked.map(\.number) == ["1", "2", "3", "4", "5"])
    }

    // MARK: production.json

    @Test func fileRoundTrips() throws {
        var file = ProductionFile()
        file.scenes = Array(Self.locked.prefix(2))
        file.pages = [PageAnchor(page: "1", at: "start"), PageAnchor(page: "2", at: "s002 dialogue-3", row: 2, text: "I haven't")]
        file.revisions = [ScriptRevision(color: .blue, date: "2026-11-23")]
        file.root["notes"] = .string("kept")
        let reread = try ProductionFile(text: file.text)
        #expect(reread == file)
        #expect(reread.scenes?.count == 2)
        #expect(reread.pages?[1].row == 2)
        #expect(reread.currentRevision?.color == .blue)
        #expect(reread.nextColor == .pink)
        #expect(reread.currentBaselineFolder == "script/revisions/01 blue")
        #expect(file.text.contains("\"notes\": \"kept\""))
        #expect(ProductionFile().nextColor == .blue)
        #expect(ProductionFile().isEmpty)
        #expect(RevisionColor.cherry.next == .white)
    }

    // MARK: Revision marks

    @Test func diffMarksAddedEditedAndDeleted() {
        let old = """
        INT. KITCHEN - NIGHT {#s001}

        Rain hammers the window.

        MARA
        I haven't opened it yet.

        She sets the key down.

        The kettle screams.
        """
        let new = """
        INT. KITCHEN - NIGHT {#s001}

        Rain hammers the window.

        MARA
        I already opened it.

        She sets the key down.

        A new line here.
        """
        let parsed = ScriptParser.parse(new)
        let changed = RevisionDiff.changedLines(current: [(name: "01.md", parsed: parsed)], baseline: [(name: "01.md", text: old)])
        let texts = Set(changed.map { parsed.lines[$0.line].text })
        #expect(texts == ["I already opened it.", "A new line here."])
        // Deleting a line marks what now stands in its place.
        let shorter = ScriptParser.parse(old.replacingOccurrences(of: "\nShe sets the key down.\n", with: ""))
        let deleted = RevisionDiff.changedLines(current: [(name: "01.md", parsed: shorter)], baseline: [(name: "01.md", text: old)])
        #expect(deleted.map { shorter.lines[$0.line].text } == ["The kettle screams."])
        // A file that wasn't in the baseline is all new; a scene tag added isn't a change.
        #expect(RevisionDiff.changedLines(current: [(name: "02.md", parsed: parsed)], baseline: [(name: "01.md", text: old)]).count == 6)
        let tagged = old.replacingOccurrences(of: " {#s001}", with: " {#s001 dur=1:00}")
        #expect(RevisionDiff.changedLines(current: [(name: "01.md", parsed: ScriptParser.parse(tagged))], baseline: [(name: "01.md", text: old)]).isEmpty)
    }

    // MARK: Layout

    /// Five scenes of about a page each, with a long speech in s003.
    static func longScript(extra: String = "") -> String {
        var text = ""
        for scene in 1...5 {
            text += "INT. ROOM \(scene) - DAY {#s00\(scene)}\n\n"
            if scene == 2 { text += extra }
            // One long paragraph (consecutive lines), so pages break inside it.
            text += (1...24).map { "Scene \(scene) line \($0) has enough words to wrap across a second printed line of action." }
                .joined(separator: "\n") + "\n\n"
            if scene == 3 {
                text += "MARA\n" + (1...30).map { "Sentence \($0) of a speech that runs on and on." }.joined(separator: " ") + "\n\n"
            }
        }
        return text
    }

    static func dump(_ script: PaginatedScript) -> [String] {
        script.pages.map { page in
            "\(page.label): " + page.rows.map { "\($0.row) \($0.line.text) \($0.line.sceneNumber ?? "")" }.joined(separator: " | ")
        }
    }

    @Test func lockedPagesReproduceThenGrowAPages() throws {
        let parsed = [ScriptParser.parse(Self.longScript())]
        let original = Paginator().paginate(parsed)
        #expect(original.pageCount >= 5)
        let anchors = PageAnchors.make(from: original, files: parsed)
        #expect(anchors.count == original.pageCount)
        #expect(anchors[0].at == "start")
        #expect(anchors.contains { $0.row > 0 }) // a page starts inside a paragraph or the speech

        // Locked with nothing changed: the same pages.
        let locked = Paginator(production: ProductionLayout(pages: anchors)).paginate(parsed)
        #expect(Self.dump(locked) == Self.dump(original))

        // Text added to scene 2 spills onto A-pages; later pages keep their numbers.
        let extra = (1...20).map { "Added paragraph \($0) in the second scene.\n\n" }.joined()
        let grown = [ScriptParser.parse(Self.longScript(extra: extra))]
        let regrown = Paginator(production: ProductionLayout(pages: anchors)).paginate(grown)
        let labels = regrown.pages.map(\.label)
        #expect(labels.contains { $0.hasSuffix("A") })
        #expect(Array(labels.suffix(2)) == Array(original.pages.map(\.label).suffix(2)))
        // Unlocked, the same text just renumbers.
        #expect(Paginator().paginate(grown).pages.allSatisfy { Int($0.label) != nil })
    }

    @Test func aCutPageStartPrintsOmitted() {
        let parsed = [ScriptParser.parse(Self.longScript())]
        var anchors = PageAnchors.make(from: Paginator().paginate(parsed), files: parsed)
        anchors.insert(PageAnchor(page: "2A", at: "s099 action-1", text: "Gone"), at: 2)
        let pages = Paginator(production: ProductionLayout(pages: anchors)).paginate(parsed).pages
        let omitted = pages.first { $0.omitted }
        #expect(omitted?.label == "2A")
        #expect(omitted?.rows.first?.line.text == "OMITTED")
    }

    @Test func labelsOmittedScenesAndRevisionHeaders() {
        let text = "INT. A - DAY {#s001}\n\nOne.\n\nINT. C - DAY {#s003}\n\nThree.\n\nINT. NEW - DAY {#s009}\n\nNew.\n"
        let parsed = [ScriptParser.parse(text)]
        let production = ProductionLayout(
            sceneLabels: ["1", "3", "3A"],
            omitted: [OmittedScene(before: 1, number: "2", heading: "INT. B - DAY")],
            changed: [SourceRef(file: 0, line: 10)],
            revision: ScriptRevision(color: .pink, date: "2026-11-23")
        )
        let page = Paginator(production: production).paginate(parsed).pages[0]
        let numbered = page.rows.compactMap { row in row.line.sceneNumber.map { "\($0) \(row.line.text)" } }
        #expect(numbered == ["1 INT. A - DAY", "2 OMITTED", "3 INT. C - DAY", "3A INT. NEW - DAY"])
        #expect(page.rows.filter(\.line.revised).map(\.line.text) == ["New."])
        #expect(page.revision?.color == .pink)
        #expect(page.rows.first { $0.line.text == "Three." }?.line.scene == 1)
    }

    @Test func makeLayoutFromTheFile() {
        let text = "INT. A - DAY {#s001}\n\nOne.\n\nINT. NEW - DAY {#s009}\n\nNew.\n"
        var file = ProductionFile()
        file.scenes = [LockedScene(id: "s001", number: "1", heading: "INT. A - DAY"), LockedScene(id: "s002", number: "2", heading: "INT. B - DAY")]
        file.revisions = [ScriptRevision(color: .blue, date: "2026-11-23")]
        let parsed = ScriptParser.parse(text)
        let layout = ProductionLayout.make(files: [(name: "script.md", parsed: parsed)], production: file,
                                           baseline: [(name: "script.md", text: "INT. A - DAY {#s001}\n\nOne.\n")])
        #expect(layout.sceneLabels == ["1", "1A"])
        #expect(layout.omitted == [OmittedScene(before: 2, number: "2", heading: "INT. B - DAY")])
        #expect(layout.changed.map { parsed.lines[$0.line].text }.sorted() == ["INT. NEW - DAY {#s009}", "New."])
    }

    // MARK: Reports

    static let reportScript = """
    INT. KITCHEN - NIGHT {#s001}

    Rain.

    MARA
    I haven't opened it yet.

    OLDER MARA (O.S.)
    You already have.

    EXT. ROOF - DAWN {#s002}

    Wind.

    MARA
    Hello, again.

    I/E. KITCHEN - DAY {#s003}

    THOMAS
    Morning.
    """

    @Test func reportsListScenesCharactersAndLocations() {
        let parsed = [ScriptParser.parse(Self.reportScript)]
        let paginated = Paginator().paginate(parsed)
        let labels = ["1", "2", "2A"]
        let scenes = ProductionReports.scenes(files: parsed, paginated: paginated, labels: labels)
        #expect(scenes.map(\.number) == labels)
        #expect(scenes.map(\.setting) == ["INT", "EXT", "INT/EXT"])
        #expect(scenes.map(\.location) == ["KITCHEN", "ROOF", "KITCHEN"])
        #expect(scenes[0].cast == ["MARA", "OLDER MARA"])
        #expect(scenes[0].page == "1")
        #expect(scenes[1].time == "DAWN")

        let characters = ProductionReports.characters(scenes)
        #expect(characters.map(\.name) == ["MARA", "OLDER MARA", "THOMAS"])
        #expect(characters[0].scenes == ["1", "2"])
        #expect(characters[0].words == 7) // "I haven't opened it yet." + "Hello, again."

        let locations = ProductionReports.locations(scenes)
        #expect(locations.map(\.location) == ["KITCHEN", "ROOF"])
        #expect(locations[0].settings == ["INT", "INT/EXT"])
        #expect(locations[0].scenes == ["1", "2A"])

        let rows = ProductionReport.scenes.rows(files: parsed, paginated: paginated, labels: labels)
        #expect(rows[0] == ["1", "INT", "KITCHEN", "NIGHT", scenes[0].eighths == 8 ? "1" : ScriptEstimate.formatEighths(scenes[0].eighths), "1", "MARA, OLDER MARA"])
        let csv = ProductionReports.csv(header: ProductionReport.scenes.columns, rows: rows)
        #expect(csv.hasPrefix("Scene,Int/Ext,Location,Time,Pages,Page,Cast\r\n1,INT,KITCHEN,NIGHT,"))
        #expect(csv.contains("\"MARA, OLDER MARA\""))
        #expect(ProductionReports.csv(header: ["a"], rows: [["say \"hi\""]]) == "a\r\n\"say \"\"hi\"\"\"\r\n")
    }
}
