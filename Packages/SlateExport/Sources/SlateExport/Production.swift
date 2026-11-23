import CoreGraphics
import CoreText
import Foundation
import SlateCore

/// Reports and sides, from the same layout Publish prints.
extension Publisher {
    /// A report as CSV (`csv: true`) or a PDF table.
    public static func report(_ report: ProductionReport, csv: Bool, _ source: ScriptSource) -> Data {
        let parsed = source.parsed
        let layout = source.productionLayout(parsed)
        let paginated = Paginator(settings: source.settings, production: layout).paginate(parsed)
        let rows = report.rows(files: parsed, paginated: paginated, labels: source.sceneLabels, omitted: layout?.omitted ?? [])
        if csv { return Data(ProductionReports.csv(header: report.columns, rows: rows).utf8) }
        return TablePDF(title: "\(source.projectName) — \(report.title)", columns: report.columns, rows: rows,
                        widths: report.columnWidths, pageSize: source.settings.pageSize).render()
    }

    /// Writes a report to `exports/` and returns its URL.
    @discardableResult
    public static func exportReport(_ report: ProductionReport, csv: Bool, _ source: ScriptSource, projectRoot: URL) throws -> URL {
        let url = destination(kind: report.title, extension: csv ? "csv" : "pdf", projectName: source.projectName, projectRoot: projectRoot)
        try CoordinatedFileIO.write(self.report(report, csv: csv, source), to: url)
        return url
    }

    /// Sides: the script pages that show the chosen scenes (by ID), with
    /// everything else on those pages crossed out.
    public static func sides(sceneIDs: Set<String>, _ source: ScriptSource) -> Data {
        let parsed = source.parsed
        let paginated = Paginator(settings: source.settings, production: source.productionLayout(parsed)).paginate(parsed)
        let all = parsed.flatMap(\.scenes)
        let labels = source.sceneLabels
        let chosen = Set(all.indices.filter { all[$0].sceneID.map(sceneIDs.contains) ?? false })
        let numbers = chosen.sorted().map { labels.indices.contains($0) ? labels[$0] : String($0 + 1) }
        let header = "SIDES · \(numbers.count == 1 ? "Scene" : "Scenes") \(numbers.joined(separator: ", "))"
        return PDFRenderer(paginated: paginated, documentTitle: "\(source.projectName) — Sides", emphasis: source.settings.emphasis,
                           sides: chosen, sidesHeader: header).render()
    }

    @discardableResult
    public static func exportSides(sceneIDs: Set<String>, _ source: ScriptSource, projectRoot: URL) throws -> URL {
        let url = destination(kind: "Sides", extension: "pdf", projectName: source.projectName, projectRoot: projectRoot)
        try CoordinatedFileIO.write(sides(sceneIDs: sceneIDs, source), to: url)
        return url
    }
}

extension ProductionReport {
    /// Relative column widths for the PDF.
    var columnWidths: [Double] {
        switch self {
        case .scenes: [0.7, 0.8, 2.6, 1, 0.7, 0.6, 3.2]
        case .characters: [2, 0.8, 0.9, 0.8, 0.9, 4]
        case .locations: [3, 1, 0.8, 0.8, 3.6]
        }
    }
}

/// A plain table on landscape pages, with the header repeated on each page.
struct TablePDF {
    var title: String
    var columns: [String]
    var rows: [[String]]
    var widths: [Double]
    var pageSize: PageSize

    func render() -> Data {
        let page = pageSize == .a4 ? CGSize(width: 842, height: 595) : CGSize(width: 792, height: 612)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(origin: .zero, size: page)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title, kCGPDFContextCreator: "Slate"] as CFDictionary)
        else { return Data() }
        let margin: CGFloat = 36, padding: CGFloat = 4
        let total = widths.reduce(0, +)
        let columnWidths = widths.map { CGFloat($0 / total) * (page.width - 2 * margin) }
        let font = AnimaticPainter.systemFont(9), bold = AnimaticPainter.systemFont(9, bold: true)
        let black = CGColor(gray: 0, alpha: 1)

        func height(_ cells: [String], _ font: CTFont) -> CGFloat {
            zip(cells, columnWidths).map { text, width in
                let setter = CTFramesetterCreateWithAttributedString(AnimaticPainter.attributed(text, font: font, color: black, alignment: .left))
                return CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width - 2 * padding, height: 1000), nil).height
            }.max().map { ceil($0) + 2 * padding } ?? 14
        }
        func drawRow(_ cells: [String], _ font: CTFont, top: CGFloat, rowHeight: CGFloat, shade: Bool) {
            if shade {
                context.setFillColor(CGColor(gray: 0.94, alpha: 1))
                context.fill(CGRect(x: margin, y: top - rowHeight, width: page.width - 2 * margin, height: rowHeight))
            }
            var x = margin
            for (text, width) in zip(cells, columnWidths) {
                AnimaticPainter.drawText(text, font: font, color: black,
                                         in: CGRect(x: x + padding, y: top - rowHeight + padding, width: width - 2 * padding, height: rowHeight - 2 * padding),
                                         context: context, alignment: .left)
                x += width
            }
        }

        var pageNumber = 0
        var top: CGFloat = 0
        func newPage() {
            if pageNumber > 0 { context.endPDFPage() }
            pageNumber += 1
            context.beginPDFPage(nil)
            AnimaticPainter.drawText(title, font: AnimaticPainter.systemFont(12, bold: true), color: black,
                                     in: CGRect(x: margin, y: page.height - margin - 16, width: page.width * 0.7, height: 16),
                                     context: context, alignment: .left, maxLines: 1)
            AnimaticPainter.drawText("\(pageNumber)", font: font, color: CGColor(gray: 0.4, alpha: 1),
                                     in: CGRect(x: page.width / 2, y: page.height - margin - 14, width: page.width / 2 - margin, height: 14),
                                     context: context, alignment: .right, maxLines: 1)
            top = page.height - margin - 28
            let headerHeight = height(columns, bold)
            drawRow(columns, bold, top: top, rowHeight: headerHeight, shade: false)
            top -= headerHeight
            context.setStrokeColor(black)
            context.setLineWidth(0.75)
            context.move(to: CGPoint(x: margin, y: top))
            context.addLine(to: CGPoint(x: page.width - margin, y: top))
            context.strokePath()
        }
        newPage()
        for (index, row) in rows.enumerated() {
            let rowHeight = height(row, font)
            if top - rowHeight < margin { newPage() }
            drawRow(row, font, top: top, rowHeight: rowHeight, shade: index % 2 == 1)
            top -= rowHeight
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
