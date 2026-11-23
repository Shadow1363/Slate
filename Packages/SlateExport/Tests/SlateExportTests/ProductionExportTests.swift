import Foundation
import PDFKit
import Testing
@testable import SlateCore
@testable import SlateExport

@Suite("Production export")
struct ProductionExportTests {
    /// Three scenes of about a page each.
    static func script(extraInScene2: Int = 0) -> String {
        (1...3).map { scene in
            var text = "INT. ROOM \(scene) - DAY {#s00\(scene)}\n\n"
            let lines = 22 + (scene == 2 ? extraInScene2 : 0)
            text += (1...lines).map { "Scene \(scene) line \($0) has words enough to wrap onto a second printed line." }.joined(separator: "\n")
            if scene == 2 { text += "\n\nMARA\nWe should go." }
            return text + "\n\n"
        }.joined()
    }

    static func source(_ text: String, production: ProductionFile?, baseline: String? = nil) -> ScriptSource {
        ScriptSource(projectName: "Film", titlePage: "Title: Film\n", files: [(name: "script.md", text: text)],
                     settings: PublishSettings(), production: production,
                     baseline: baseline.map { [(name: "script.md", text: $0)] })
    }

    @Test func lockedPagesAndRevisionsPrint() throws {
        let original = Self.script()
        let parsed = [ScriptParser.parse(original)]
        var production = ProductionFile()
        production.scenes = SceneNumbering.lock(SceneNumbering.scenes(in: parsed), existing: nil)
        production.pages = PageAnchors.make(from: Paginator().paginate(parsed), files: parsed)
        production.revisions = [ScriptRevision(color: .blue, date: "2026-11-23")]

        // Scene 2 grows: its page spills onto an A-page, and the new lines are marked.
        let grown = Self.script(extraInScene2: 30)
        let source = Self.source(grown, production: production, baseline: original)
        let pages = source.paginated.pages
        #expect(pages.map(\.label).contains { $0.hasSuffix("A") })
        #expect(pages.contains { $0.revision != nil })

        let document = try #require(PDFDocument(data: Publisher.pdf(source)))
        let text = (1..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        #expect(text.contains("Blue Rev. (11/23/26)"))
        #expect(text.contains("*"))
        let aLabel = try #require(pages.first { $0.label.hasSuffix("A") }?.label)
        #expect(text.contains(aLabel + "."))
        // Unchanged pages have no revision header.
        #expect(pages.contains { $0.revision == nil })
        #expect(PDFRenderer.shortDate("2026-11-23") == "11/23/26")
    }

    @Test func sidesKeepOnlyPagesWithTheChosenScenes() throws {
        let source = Self.source(Self.script(), production: nil)
        let all = source.paginated.pages
        let withScene2 = all.filter { $0.rows.contains { $0.line.scene == 1 } }
        let document = try #require(PDFDocument(data: Publisher.sides(sceneIDs: ["s002"], source)))
        #expect(document.pageCount == withScene2.count)
        #expect(document.pageCount < all.count + 1)
        #expect(document.page(at: 0)?.string?.contains("SIDES · Scene 2") == true)
        #expect(document.page(at: 0)?.string?.contains("Title: Film") != true)
    }

    @Test func reportsAsCSVAndPDF() throws {
        let source = Self.source(Self.script(), production: nil)
        let csv = String(decoding: Publisher.report(.locations, csv: true, source), as: UTF8.self)
        #expect(csv.hasPrefix("Location,Int/Ext,Scenes,Pages,Scene Numbers\r\n"))
        #expect(csv.contains("ROOM 2,INT,1,"))
        let pdf = try #require(PDFDocument(data: Publisher.report(.scenes, csv: false, source)))
        #expect(pdf.page(at: 0)?.string?.contains("Film — Scene List") == true)
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).width == 792)
        let url = Publisher.destination(kind: "Scene List", extension: "csv", projectName: "Film",
                                        projectRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(url.lastPathComponent.hasPrefix("Film – Scene List – "))
    }
}
