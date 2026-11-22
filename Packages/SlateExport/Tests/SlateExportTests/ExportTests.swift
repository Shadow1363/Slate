import Foundation
import PDFKit
import Testing
@testable import SlateCore
@testable import SlateExport

/// A readable dump of a layout, one line per printed line:
/// `p2 r10  x2.50 L  Beer's ready!`
private func layoutDump(_ script: PaginatedScript) -> String {
    script.pages.flatMap { page in
        page.rows.map { row in
            let align = switch row.line.alignment { case .left: "L"; case .right: "R"; case .center: "C" }
            let number = row.line.sceneNumber.map { " #\($0)" } ?? ""
            return String(format: "p%d r%02d x%.2f %@ ", page.number, row.row, row.line.x, align) + row.line.text + number
        }
    }.joined(separator: "\n") + "\n"
}

@Suite("PDF")
struct PDFTests {
    @Test func bundledFontLoads() {
        let font = SlateFonts.font(size: 12)
        #expect((CTFontCopyFamilyName(font) as String) == "Courier Prime")
        #expect((CTFontCopyFamilyName(SlateFonts.font(size: 12, bold: true, italic: true)) as String) == "Courier Prime")
        // 10 characters per inch.
        var glyph = CGGlyph(0)
        var character = UniChar(("M" as Character).utf16.first!)
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        #expect(abs(advance.width - 7.2) < 0.01)
    }

    @Test func renderedPDFHasTheLayoutsPagesAndText() throws {
        let source = try brickAndSteelSource()
        let data = Publisher.pdf(source)
        let document = try #require(PDFDocument(data: data))
        let paginated = source.paginated
        #expect(document.pageCount == paginated.pageCount + 1, "title page + script pages")
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "BRICK & STEEL")

        let titleText = try #require(document.page(at: 0)?.string)
        #expect(titleText.contains("BRICK & STEEL"))
        #expect(titleText.contains("Stu Maschwitz"))

        let first = try #require(document.page(at: 1)?.string)
        #expect(first.contains("EXT. BRICK'S PATIO - DAY"))
        #expect(!first.contains("1."), "no page number on page 1")
        let second = try #require(document.page(at: 2)?.string)
        #expect(second.hasPrefix("2.") || second.contains("\n2.") || second.contains("2.\n"))

        // Scene numbers print in both margins.
        // (PDFKit reads the left and right numbers as one "1 1" run.)
        let numbered = ReferencePDF.lines(at: try writeTemp(data, name: "numbered.pdf"))
        #expect(numbered[0][0].text == "1 1 EXT. BRICK'S PATIO - DAY")

        // Lines land where the layout says (scene numbers off so they don't join the text).
        var plain = source
        plain.settings.sceneNumbers = false
        let reread = ReferencePDF.lines(at: try writeTemp(Publisher.pdf(plain), name: "brick.pdf"))
        #expect(reread.count == paginated.pageCount)
        for (ours, theirs) in zip(plain.paginated.pageLines, reread) {
            #expect(ours.map { Normalize.key($0.text) } == theirs.map { Normalize.key($0.text) })
            #expect(ours.map(\.row) == theirs.map(\.row))
        }
    }

    @Test func layoutSnapshot() throws {
        let dump = layoutDump(try brickAndSteelSource().paginated)
        let golden = Fixtures.root.appending(path: "Snapshots/brick-and-steel.layout.txt")
        if ProcessInfo.processInfo.environment["SLATE_UPDATE_SNAPSHOTS"] == "1" || !FileManager.default.fileExists(atPath: golden.path) {
            try FileManager.default.createDirectory(at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try dump.write(to: golden, atomically: true, encoding: .utf8)
        }
        #expect(dump == (try String(contentsOf: golden, encoding: .utf8)), "layout changed; rerun with SLATE_UPDATE_SNAPSHOTS=1 if intended")
    }

    @Test func exportsGoToTheExportsFolderWithoutOverwriting() throws {
        let folder = try TempDir()
        let root = try ProjectCreator.create(title: "Film", template: .short, in: folder.url)
        let source = ScriptSource(projectName: "Film", titlePage: "Title: Film\n", files: [("script.md", "# INT. A {#s001}\n\nGo.\n")], settings: PublishSettings())
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        let first = Publisher.destination(for: .pdf, projectName: "Film", projectRoot: root, date: date)
        try Data("x".utf8).write(to: first)
        let second = Publisher.destination(for: .pdf, projectName: "Film", projectRoot: root, date: date)
        #expect(first.deletingLastPathComponent().lastPathComponent == "exports")
        #expect(second.lastPathComponent.hasSuffix(" 2.pdf"))
        for format in ExportFormat.allCases where format.isAvailable {
            let url = try Publisher.export(format, source, projectRoot: root)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(url.pathExtension == format.fileExtension)
        }
    }
}

@Suite("Fountain import and export")
struct FountainTests {
    @Test func topLevelSectionsBecomeActFiles() throws {
        let imported = FountainImporter.convert(try Fixtures.text("The-Last-Birthday-Card.fountain"))
        #expect(imported.files.map(\.name) == ["01-act-i.md", "02-act-ii-a-new-day.md", "03-act-iii-the-showdown.md"])
        #expect(TitlePage.parse(imported.titlePage).title == "**THE LAST BIRTHDAY CARD**")
        let first = imported.files[0].text
        #expect(first.contains("/* ## Meet Scott */"))
        #expect(first.contains("# BACK IN THE APARTMENT {#"))
        // Scene IDs are unique across all act files.
        let ids = imported.files.flatMap { ScriptParser.parse($0.text).scenes.compactMap(\.sceneID) }
        #expect(ids.count == Set(ids).count)
        #expect(ids.count == imported.files.flatMap { ScriptParser.parse($0.text).scenes }.count)
    }

    @Test func notesBecomeCommentsNotLinks() {
        let imported = FountainImporter.convert("INT. A\n\nShe waits. [[Check the timing.]]\n")
        #expect(imported.files[0].text.contains("She waits. /* note: Check the timing. */"))
    }

    @Test func noSectionsMeansOneScriptFile() throws {
        let imported = FountainImporter.convert(try Fixtures.text("Brick-and-Steel.fountain"))
        #expect(imported.files.map(\.name) == ["script.md"])
        #expect(TitlePage.parse(imported.titlePage).values("Author") == ["Stu Maschwitz"])
    }

    @Test func roundTripKeepsElementsAndActs() throws {
        let imported = FountainImporter.convert(try Fixtures.text("The-Last-Birthday-Card.fountain"))
        let exported = FountainExporter.export(titlePage: imported.titlePage, files: imported.files.map { ($0.name, $0.text) })
        let again = FountainImporter.convert(exported)
        #expect(again.files.map(\.name) == imported.files.map(\.name))
        #expect(again.titlePage == imported.titlePage)
        for (a, b) in zip(imported.files, again.files) {
            let kindsA = ScriptParser.parse(a.text).lines.map(\.kind).filter { $0 != .blank && $0 != .boneyard }
            let kindsB = ScriptParser.parse(b.text).lines.map(\.kind).filter { $0 != .blank && $0 != .boneyard }
            #expect(kindsA == kindsB)
            #expect(ScriptParser.parse(a.text).scenes.map(\.heading) == ScriptParser.parse(b.text).scenes.map(\.heading))
        }
    }

    @Test func exportUsesPlainFountain() {
        let out = FountainExporter.export(titlePage: "Title: A\n", files: [("script.md", "# INT. A {#s001}\n\nSee [[Mara|her]].\n\n# MONTAGE {#s002}\n\nThings.\n")])
        #expect(out == "Title: A\n\nINT. A\n\nSee her.\n\n.MONTAGE\n\nThings.\n")
    }
}

@Suite("Final Draft")
struct FDXTests {
    @Test func roundTripKeepsElementsIDsAndTitlePage() throws {
        let imported = FountainImporter.convert(try Fixtures.text("Brick-and-Steel.fountain"))
        let xml = FDXExporter.export(titlePage: imported.titlePage, files: imported.files.map { ($0.name, $0.text) })
        #expect(xml.contains(#"<FinalDraft DocumentType="Script" Template="No" Version="5">"#))
        #expect(xml.contains(#"<Paragraph Type="Scene Heading" Number="1" SlateSceneID="s001">"#))
        #expect(xml.contains("<DualDialogue>"))

        let back = try FDXImporter.convert(Data(xml.utf8))
        let original = ScriptParser.parse(imported.files[0].text)
        let reread = ScriptParser.parse(back.files[0].text)
        let printed = { (p: ParsedScript) in p.lines.filter { ![.blank, .boneyard, .synopsis].contains($0.kind) }.map { "\($0.kind) \(ScriptEstimate.printedText(of: $0))" } }
        #expect(printed(reread).count == printed(original).count)
        #expect(reread.scenes.map(\.sceneID) == original.scenes.map(\.sceneID))
        #expect(reread.scenes.map(\.heading) == original.scenes.map(\.heading))
        #expect(TitlePage.parse(back.titlePage).values("Author") == ["Stu Maschwitz"])
        #expect(TitlePage.parse(back.titlePage).values("Contact").count == 3)
    }

    @Test func roundTripPaginatesTheSame() throws {
        let imported = FountainImporter.convert(try Fixtures.text("Brick-and-Steel.fountain"))
        let xml = FDXExporter.export(titlePage: imported.titlePage, files: imported.files.map { ($0.name, $0.text) })
        let back = try FDXImporter.convert(Data(xml.utf8))
        let a = Paginator().paginate(imported.files.map { ScriptParser.parse($0.text) })
        let b = Paginator().paginate(back.files.map { ScriptParser.parse($0.text) })
        #expect(a.pageLines.map { $0.map { Normalize.key($0.text) } } == b.pageLines.map { $0.map { Normalize.key($0.text) } })
    }

    @Test func importsStylesAndNumbers() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
        <FinalDraft DocumentType="Script" Template="No" Version="4">
          <Content>
            <Paragraph Number="14" Type="Scene Heading"><Text>int. kitchen - night</Text></Paragraph>
            <Paragraph Type="Action"><Text>She sees </Text><Text Style="Bold">THE KEY</Text><Text>.</Text></Paragraph>
            <Paragraph Type="Character"><Text>MARA</Text></Paragraph>
            <Paragraph Type="Parenthetical"><Text>(quietly)</Text></Paragraph>
            <Paragraph Type="Dialogue"><Text>Hi.</Text></Paragraph>
            <Paragraph Type="Transition"><Text>FADE OUT.</Text></Paragraph>
          </Content>
        </FinalDraft>
        """
        let imported = try FDXImporter.convert(Data(xml.utf8))
        #expect(imported.files[0].text == "# INT. KITCHEN - NIGHT {#s001 number=14}\n\nShe sees **THE KEY**.\n\nMARA\n(quietly)\nHi.\n\n>FADE OUT.\n")
    }

    @Test func rejectsOtherXML() {
        #expect(throws: FDXError.self) { try FDXImporter.convert(Data("<html/>".utf8)) }
    }
}

@MainActor
@Suite("Import into a project")
struct ImportProjectTests {
    @Test func createsAProjectWithActFiles() throws {
        let folder = try TempDir()
        let root = try Publisher.createProject(from: Fixtures.fountain.appending(path: "The-Last-Birthday-Card.fountain"), in: folder.url)
        #expect(root.lastPathComponent == "THE LAST BIRTHDAY CARD")
        let store = try ProjectStore(rootURL: root, autosaveDelay: nil)
        #expect(ScriptBook.scriptFiles(in: store.files[.script] ?? []).map(\.name) == ["01-act-i.md", "02-act-ii-a-new-day.md", "03-act-iii-the-showdown.md"])
        #expect(try store.readText(at: "script/title-page.md").contains("Stu Maschwitz"))
    }
}

// MARK: - Helpers

final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "SlateExportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func writeTemp(_ data: Data, name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
    try data.write(to: url)
    return url
}

private func brickAndSteelSource() throws -> ScriptSource {
    let imported = FountainImporter.convert(try Fixtures.text("Brick-and-Steel.fountain"))
    return ScriptSource(
        projectName: "Brick & Steel",
        titlePage: imported.titlePage,
        files: imported.files.map { ($0.name, $0.text) },
        settings: PublishSettings()
    )
}
