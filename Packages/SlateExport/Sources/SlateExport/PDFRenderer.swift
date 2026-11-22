import CoreGraphics
import CoreText
import Foundation
import SlateCore

/// Courier Prime, bundled under the SIL Open Font License (see `Resources/Fonts/OFL.txt`).
public enum SlateFonts {
    public static let familyName = "Courier Prime"

    private static let urls: [URL] = {
        guard let folder = Bundle.module.url(forResource: "Fonts", withExtension: nil) else { return [] }
        return ["Regular", "Bold", "Italic", "BoldItalic"].map { folder.appending(path: "CourierPrime-\($0).ttf") }
    }()

    /// CTFontDescriptor is immutable and thread-safe, so sharing it is fine.
    nonisolated(unsafe) private static let descriptors: [String: CTFontDescriptor] = {
        var result: [String: CTFontDescriptor] = [:]
        for (style, url) in zip(["Regular", "Bold", "Italic", "BoldItalic"], urls) {
            if let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let first = list.first {
                result[style] = first
            }
        }
        return result
    }()

    private static let registration: Bool = {
        var ok = true
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered (e.g. installed by the user) is fine.
                ok = false
            }
        }
        return ok
    }()

    /// Makes "Courier Prime" available by name to the whole app (the editor
    /// themes use it). Safe to call more than once.
    public static func register() {
        _ = registration
    }

    /// The bundled font, loaded straight from the file so output never
    /// depends on what is installed.
    public static func font(size: Double, bold: Bool = false, italic: Bool = false) -> CTFont {
        let style = bold && italic ? "BoldItalic" : bold ? "Bold" : italic ? "Italic" : "Regular"
        if let descriptor = descriptors[style] {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        return CTFontCreateWithName("Courier" as CFString, size, nil)
    }
}

/// Draws a paginated script (and its title page) into a PDF with Core Text.
/// The editor theme never affects this: Publish always uses the industry layout.
public struct PDFRenderer {
    public var paginated: PaginatedScript
    public var titlePage: TitlePage
    public var documentTitle: String
    public var emphasis: Bool

    public init(paginated: PaginatedScript, titlePage: TitlePage = TitlePage(), documentTitle: String, emphasis: Bool = true) {
        self.paginated = paginated
        self.titlePage = titlePage
        self.documentTitle = documentTitle
        self.emphasis = emphasis
    }

    private var format: ScreenplayFormat { paginated.format }
    private var pageHeight: CGFloat { format.pageHeight * 72 }
    private var lineHeight: CGFloat { 72 / format.linesPerInch }

    public func render() -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(x: 0, y: 0, width: format.pageWidth * 72, height: pageHeight)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: documentTitle,
            kCGPDFContextCreator: "Slate",
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }

        if !titlePage.isEmpty {
            context.beginPDFPage(nil)
            drawTitlePage(in: context)
            context.endPDFPage()
        }
        for page in paginated.pages {
            context.beginPDFPage(nil)
            draw(page, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    public func write(to url: URL) throws {
        try CoordinatedFileIO.write(render(), to: url)
    }

    // MARK: - Pages

    private func draw(_ page: PrintedPage, in context: CGContext) {
        if page.number > 1 {
            drawText([PrintedRun("\(page.number).")], x: format.pageNumberRightEdge, alignment: .right,
                     top: format.pageNumberTop * 72, in: context)
        }
        for row in page.rows {
            let top = CGFloat(format.topMargin * 72) + CGFloat(row.row) * lineHeight
            drawText(row.line.runs, x: row.line.x, alignment: row.line.alignment, top: top, in: context)
            if let number = row.line.sceneNumber {
                drawText([PrintedRun(number)], x: format.sceneNumberLeft, alignment: .left, top: top, in: context)
                drawText([PrintedRun(number)], x: format.sceneNumberRight, alignment: .left, top: top, in: context)
            }
        }
    }

    /// Title, credit, authors, source and draft date centred about a third of
    /// the way down; contact bottom-left.
    private func drawTitlePage(in context: CGContext) {
        let center = format.pageWidth / 2
        var row = 18
        func centered(_ values: [String], gapAfter: Int) {
            guard !values.isEmpty else { return }
            for value in values {
                let runs = Emphasis.runs(in: value, enabled: emphasis)
                drawText(runs, x: center, alignment: .center, top: CGFloat(format.topMargin * 72) + CGFloat(row) * lineHeight, in: context)
                row += 1
            }
            row += gapAfter
        }
        centered(titlePage.values("Title"), gapAfter: 3)
        centered(titlePage.values("Credit"), gapAfter: 1)
        centered(titlePage.values("Author") + titlePage.values("Authors"), gapAfter: 2)
        centered(titlePage.values("Source"), gapAfter: 2)
        centered(titlePage.values("Draft date"), gapAfter: 0)

        let contact = titlePage.values("Contact")
        var contactRow = format.linesPerPage - contact.count
        for value in contact {
            drawText(Emphasis.runs(in: value, enabled: emphasis), x: format.action.x, alignment: .left,
                     top: CGFloat(format.topMargin * 72) + CGFloat(contactRow) * lineHeight, in: context)
            contactRow += 1
        }
    }

    // MARK: - Text

    /// Draws one line whose text box starts `top` points below the top of the page.
    private func drawText(_ runs: [PrintedRun], x: Double, alignment: LineAlignment, top: CGFloat, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(attributedString(runs))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        var originX = CGFloat(x * 72)
        switch alignment {
        case .left: break
        case .right: originX -= CGFloat(width)
        case .center: originX -= CGFloat(width) / 2
        }
        let ascent = CTFontGetAscent(SlateFonts.font(size: format.fontSize))
        context.textPosition = CGPoint(x: originX, y: pageHeight - top - ascent)
        CTLineDraw(line, context)
    }

    private func attributedString(_ runs: [PrintedRun]) -> CFAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): SlateFonts.font(size: format.fontSize, bold: run.bold, italic: run.italic),
            ]
            if run.underline {
                attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result as CFAttributedString
    }
}
