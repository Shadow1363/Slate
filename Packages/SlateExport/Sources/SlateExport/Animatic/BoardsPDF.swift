import CoreGraphics
import CoreText
import Foundation
import SlateCore

/// The storyboard as a PDF: 2, 4 or 6 frames per landscape page, each with
/// its scene, shot details and caption. Empty scenes get their placeholder card.
public struct BoardsPDF: Sendable {
    public enum Layout: Int, Sendable, CaseIterable, Identifiable {
        case two = 2, four = 4, six = 6

        public var id: Int { rawValue }
        public var title: String { "\(rawValue) per Page" }

        var grid: (columns: Int, rows: Int) {
            switch self {
            case .two: (2, 1)
            case .four: (2, 2)
            case .six: (3, 2)
            }
        }
    }

    public var timeline: AnimaticTimeline
    public var projectName: String
    public var layout: Layout
    public var pageSize: PageSize

    public init(timeline: AnimaticTimeline, projectName: String, layout: Layout = .four, pageSize: PageSize = .letter) {
        self.timeline = timeline
        self.projectName = projectName
        self.layout = layout
        self.pageSize = pageSize
    }

    public var pageCount: Int {
        let perPage = layout.rawValue
        return max(1, (timeline.segments.count + perPage - 1) / perPage)
    }

    /// Landscape points.
    var page: CGSize {
        switch pageSize {
        case .letter: CGSize(width: 792, height: 612)
        case .a4: CGSize(width: 842, height: 595)
        }
    }

    /// Renders the PDF, reading images and clip posters from the project.
    public func render(root: URL) async -> Data {
        var pictures: [String: CGImage] = [:]
        for segment in timeline.segments {
            switch segment.content {
            case .image(let path):
                pictures[segment.id] = AnimaticPainter.loadImage(at: root.appending(path: path), maxPixels: 1400)
            case .clip(let path, let start, _):
                pictures[segment.id] = await AnimaticComposer.poster(of: root.appending(path: path), at: start)
            case .placeholder:
                break
            }
        }
        return render(pictures: pictures)
    }

    func render(pictures: [String: CGImage]) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(origin: .zero, size: page)
        let info: [CFString: Any] = [kCGPDFContextTitle: "\(projectName) – Storyboard", kCGPDFContextCreator: "Slate"]
        guard let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }

        let margin: CGFloat = 36, header: CGFloat = 28, gap: CGFloat = 18, textHeight: CGFloat = 64
        let (columns, rows) = layout.grid
        let cellWidth = (page.width - 2 * margin - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let cellHeight = (page.height - 2 * margin - header - CGFloat(rows - 1) * gap) / CGFloat(rows)
        let pictureHeight = min(cellWidth / timeline.guide.ratio, cellHeight - textHeight)
        let pictureWidth = pictureHeight * timeline.guide.ratio
        let total = pageCount
        let segments = timeline.segments

        for pageIndex in 0..<total {
            context.beginPDFPage(nil)
            let title = AnimaticPainter.systemFont(11, bold: true)
            AnimaticPainter.drawText(projectName + " — Storyboard", font: title, color: CGColor(gray: 0, alpha: 1),
                                     in: CGRect(x: margin, y: page.height - margin - 16, width: page.width / 2, height: 16),
                                     context: context, alignment: .left, maxLines: 1)
            AnimaticPainter.drawText("\(pageIndex + 1) / \(total)", font: AnimaticPainter.systemFont(10), color: CGColor(gray: 0.4, alpha: 1),
                                     in: CGRect(x: page.width / 2, y: page.height - margin - 16, width: page.width / 2 - margin, height: 16),
                                     context: context, alignment: .right, maxLines: 1)
            let slice = segments.dropFirst(pageIndex * layout.rawValue).prefix(layout.rawValue)
            for (offset, segment) in slice.enumerated() {
                let column = offset % columns, row = offset / columns
                let x = margin + CGFloat(column) * (cellWidth + gap)
                let top = page.height - margin - header - CGFloat(row) * (cellHeight + gap)
                let pictureRect = CGRect(x: x, y: top - pictureHeight, width: pictureWidth, height: pictureHeight)
                drawCell(segment, picture: pictures[segment.id], rect: pictureRect, width: cellWidth, context: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func drawCell(_ segment: AnimaticSegment, picture: CGImage?, rect: CGRect, width: CGFloat, context: CGContext) {
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(rect)
        switch segment.content {
        case .placeholder(let text):
            AnimaticPainter.drawPlaceholder(number: segment.sceneNumber, heading: segment.heading, text: text, in: context, rect: rect)
        default:
            if let picture { AnimaticPainter.draw(picture, in: context, rect: rect) }
        }
        context.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        context.setLineWidth(0.5)
        context.stroke(rect)

        let black = CGColor(gray: 0, alpha: 1), grey = CGColor(gray: 0.35, alpha: 1)
        var y = rect.minY - 4
        func line(_ text: String, _ font: CTFont, _ color: CGColor, lines: Int = 1) {
            let height = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * CGFloat(lines) + 1
            AnimaticPainter.drawText(text, font: font, color: color, in: CGRect(x: rect.minX, y: y - height, width: width, height: height),
                                     context: context, alignment: .left, maxLines: lines)
            y -= height + 1
        }
        line("\(segment.sceneNumber)  \(segment.heading)", AnimaticPainter.systemFont(9, bold: true), black)
        var details: [String] = []
        if segment.file != nil { details.append("Frame \(segment.frameIndex + 1)") }
        if let shot = segment.shot { details.append(shot) }
        if let move = segment.move { details.append(move.prefix(1).uppercased() + move.dropFirst()) }
        details.append(String(format: "%.1f s", segment.duration))
        line(details.joined(separator: " · "), AnimaticPainter.systemFont(8), grey)
        if let caption = segment.caption, !caption.isEmpty {
            line(caption, AnimaticPainter.systemFont(9, italic: true), black, lines: layout == .six ? 2 : 3)
        }
    }

    /// `exports/<Project> – Boards – 2026-11-22.pdf`.
    public static func destination(projectName: String, projectRoot: URL) -> URL {
        Publisher.destination(for: .boards, projectName: projectName, projectRoot: projectRoot)
    }
}
