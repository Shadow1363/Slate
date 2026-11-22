import Foundation
import PDFKit
@testable import SlateCore
@testable import SlateExport

enum Fixtures {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)
    static let fountain = root.appending(path: "Fountain", directoryHint: .isDirectory)

    static func text(_ name: String) throws -> String {
        try String(contentsOf: fountain.appending(path: name), encoding: .utf8)
    }
}

/// One line of text on a page, by row.
struct PageLine: Equatable {
    var page: Int
    var row: Int
    var text: String
}

enum Normalize {
    /// Lowercased letters and digits only, so quotes, spacing and wrapping punctuation don't matter.
    static func key(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

/// Reads a reference PDF into rows (1 row = 12 pt), skipping the title page
/// and page numbers.
enum ReferencePDF {
    static func lines(at url: URL) -> [[PageLine]] {
        guard let document = PDFDocument(url: url) else { return [] }
        var pages: [[PageLine]] = []
        var raw: [(page: Int, v: Double, x: Double, text: String)] = []
        for index in 1..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            guard let selection = page.selection(for: box) else { continue }
            for line in selection.selectionsByLine() {
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let bounds = line.bounds(for: page)
                let v = (box.height - 72 - bounds.maxY) / 12
                if v < -1 { continue } // page number
                raw.append((index, v, bounds.minX / 72, text))
            }
        }
        // The top row's fractional offset differs between apps: take the most common one.
        let fractions = Dictionary(grouping: raw.map { ($0.v - $0.v.rounded(.down) * 1).truncatingRemainder(dividingBy: 1) }, by: { ($0 * 10).rounded() })
        let offset = (fractions.max { $0.value.count < $1.value.count }?.key ?? 0) / 10
        var byPage: [Int: [Int: [(Double, String)]]] = [:]
        for item in raw {
            let row = Int((item.v - offset).rounded())
            byPage[item.page, default: [:]][row, default: []].append((item.x, item.text))
        }
        for page in byPage.keys.sorted() {
            let rows = byPage[page]!
            pages.append(rows.keys.sorted().map { row in
                PageLine(page: page, row: row, text: rows[row]!.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " "))
            })
        }
        return pages
    }
}

extension PaginatedScript {
    /// Rows of each page as text (dual dialogue columns joined).
    var pageLines: [[PageLine]] {
        pages.map { page in
            let rows = Dictionary(grouping: page.rows, by: \.row)
            return rows.keys.sorted().map { row in
                PageLine(page: page.number, row: row, text: rows[row]!.sorted { $0.line.x < $1.line.x }.map(\.line.text).joined(separator: " "))
            }
        }
    }
}

/// How far each of our page breaks is from the reference's, in lines.
/// Positive: we start the page later (lines pushed onto it from before).
struct BreakComparison {
    var pageCountOurs: Int
    var pageCountReference: Int
    /// One entry per reference page after the first: (page, offset in lines, or nil if not found).
    var offsets: [(page: Int, offset: Int?)]

    var worst: Int { offsets.compactMap { $0.offset.map(abs) }.max() ?? 0 }
    var allFound: Bool { offsets.allSatisfy { $0.offset != nil } }

    static func compare(ours: PaginatedScript, reference: [[PageLine]]) -> BreakComparison {
        let mine = ours.pageLines
        var offsets: [(Int, Int?)] = []
        for (index, page) in reference.enumerated() where index > 0 {
            guard let first = page.first else { continue }
            let key = String(Normalize.key(first.text).prefix(14))
            var offset: Int?
            // Look on our matching page (pushed down) and the one before (pulled up).
            if index < mine.count, let hit = mine[index].firstIndex(where: { Normalize.key($0.text).hasPrefix(key) }), hit <= 6 {
                offset = mine[index].prefix(hit).count
            } else if index - 1 < mine.count, let hit = mine[index - 1].lastIndex(where: { Normalize.key($0.text).hasPrefix(key) }) {
                offset = -(mine[index - 1].count - hit)
            }
            offsets.append((index + 1, offset))
        }
        return BreakComparison(pageCountOurs: mine.count, pageCountReference: reference.count, offsets: offsets)
    }

    var report: String {
        "pages ours=\(pageCountOurs) reference=\(pageCountReference); offsets: " + offsets.map { "p\($0.page):\($0.offset.map(String.init) ?? "?")" }.joined(separator: " ")
    }
}

enum Samples {
    static func paginate(_ name: String, format: ScreenplayFormat, settings: PublishSettings = PublishSettings()) throws -> PaginatedScript {
        let imported = FountainImporter.convert(try Fixtures.text(name))
        let parsed = imported.files.map { ScriptParser.parse($0.text) }
        return Paginator(format: format, settings: settings).paginate(parsed)
    }

    /// *Brick & Steel*: Slate's standard format.
    static var brickAndSteelFormat: ScreenplayFormat { ScreenplayFormat() }

    /// *The Last Birthday Card*: shifted 0.25" left, one blank line before headings, wider dialogue.
    static var lastBirthdayCardFormat: ScreenplayFormat {
        var format = ScreenplayFormat().shifted(by: -0.25)
        format.headingSpacing = 1
        format.dialogue.width = 42
        return format
    }
}
