import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SlateCore

/// Which overlays to draw over the picture.
public struct AnimaticOverlays: Sendable, Equatable, Hashable {
    public var heading: Bool
    public var caption: Bool
    public var subtitles: Bool

    public init(heading: Bool = true, caption: Bool = true, subtitles: Bool = true) {
        self.heading = heading
        self.caption = caption
        self.subtitles = subtitles
    }

    public static let none = AnimaticOverlays(heading: false, caption: false, subtitles: false)
    public var isEmpty: Bool { !heading && !caption && !subtitles }
}

/// Draws animatic frames, placeholder cards and overlays with Core Graphics.
/// Shared by the compositor (video) and the boards PDF. Thread-safe: no state.
enum AnimaticPainter {
    /// The guide's frame, centred in `size` (letterboxed or pillarboxed).
    static func guideRect(_ guide: SketchGuide, in size: CGSize) -> CGRect {
        let ratio = guide.ratio
        var rect = CGRect(origin: .zero, size: size)
        if size.width / size.height > ratio {
            rect.size.width = (size.height * ratio).rounded()
            rect.origin.x = ((size.width - rect.width) / 2).rounded()
        } else {
            rect.size.height = (size.width / ratio).rounded()
            rect.origin.y = ((size.height - rect.height) / 2).rounded()
        }
        return rect
    }

    /// `image` filling `rect` (cropped to it, like a camera frame), scaled about its centre.
    static func fill(_ imageSize: CGSize, in rect: CGRect, scale: Double = 1) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let factor = max(rect.width / imageSize.width, rect.height / imageSize.height) * scale
        let size = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Draws an image filling `rect`, clipped to it.
    static func draw(_ image: CGImage, in context: CGContext, rect: CGRect, scale: Double = 1) {
        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .high
        context.draw(image, in: fill(CGSize(width: image.width, height: image.height), in: rect, scale: scale))
        context.restoreGState()
    }

    /// An empty scene's card: number and heading at the top, the first action line in the middle.
    static func drawPlaceholder(number: String, heading: String, text: String, in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 0.14, alpha: 1))
        context.fill(rect)
        let unit = rect.height / 600
        let inset = 36 * unit
        let top = "\(number)  \(heading)"
        drawText(top, font: SlateFonts.font(size: 22 * unit, bold: true), color: CGColor(gray: 0.6, alpha: 1),
                 in: CGRect(x: rect.minX + inset, y: rect.maxY - inset - 40 * unit, width: rect.width - 2 * inset, height: 40 * unit),
                 context: context, alignment: .left, maxLines: 1)
        drawText(text, font: SlateFonts.font(size: 30 * unit), color: CGColor(gray: 0.92, alpha: 1),
                 in: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.22), context: context, alignment: .center,
                 verticalCenter: true)
        context.restoreGState()
    }

    /// Scene heading, caption and subtitle over a frame of `size` (origin bottom-left).
    static func drawOverlays(_ overlays: AnimaticOverlays, segment: AnimaticSegment, cue: SubtitleCue?,
                             in context: CGContext, size: CGSize) {
        let unit = size.height / 1080
        let inset = 40 * unit
        var top = size.height - inset
        if overlays.heading {
            let text = "\(segment.sceneNumber)  \(segment.heading)"
            top -= pill(text, font: systemFont(28 * unit, bold: true), at: CGPoint(x: inset, y: top), maxWidth: size.width * 0.7,
                        context: context, unit: unit) + 10 * unit
        }
        if overlays.caption, let caption = segment.caption, !caption.isEmpty {
            _ = pill(caption, font: systemFont(24 * unit, italic: true), at: CGPoint(x: inset, y: top), maxWidth: size.width * 0.6,
                     context: context, unit: unit)
        }
        if overlays.subtitles, let cue {
            let string = NSMutableAttributedString()
            string.append(attributed(cue.character + "\n", font: systemFont(26 * unit, bold: true), color: CGColor(red: 1, green: 0.85, blue: 0.45, alpha: 1), alignment: .center))
            string.append(attributed(cue.text, font: systemFont(40 * unit), color: CGColor(gray: 1, alpha: 1), alignment: .center))
            let maxWidth = size.width * 0.72
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: maxWidth, height: size.height / 2), nil)
            let box = CGRect(x: (size.width - fitted.width) / 2, y: 60 * unit, width: ceil(fitted.width), height: ceil(fitted.height))
            context.saveGState()
            context.setFillColor(CGColor(gray: 0, alpha: 0.6))
            context.addPath(CGPath(roundedRect: box.insetBy(dx: -18 * unit, dy: -10 * unit), cornerWidth: 10 * unit, cornerHeight: 10 * unit, transform: nil))
            context.fillPath()
            context.restoreGState()
            draw(framesetter, in: box, context: context)
        }
    }

    // MARK: Text

    /// A line of text on a dark rounded backing, hanging from `point` (its top-left). Returns its height.
    private static func pill(_ text: String, font: CTFont, at point: CGPoint, maxWidth: CGFloat, context: CGContext, unit: CGFloat) -> CGFloat {
        let string = attributed(text, font: font, color: CGColor(gray: 1, alpha: 1), alignment: .left)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: maxWidth, height: 400 * unit), nil)
        let padX = 14 * unit, padY = 8 * unit
        let box = CGRect(x: point.x, y: point.y - fitted.height - 2 * padY, width: ceil(fitted.width) + 2 * padX, height: ceil(fitted.height) + 2 * padY)
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.addPath(CGPath(roundedRect: box, cornerWidth: 8 * unit, cornerHeight: 8 * unit, transform: nil))
        context.fillPath()
        context.restoreGState()
        draw(framesetter, in: box.insetBy(dx: padX, dy: padY), context: context)
        return box.height
    }

    static func systemFont(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard italic else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, .traitItalic) ?? base
    }

    static func attributed(_ text: String, font: CTFont, color: CGColor, alignment: CTTextAlignment) -> NSAttributedString {
        var align = alignment
        let style = withUnsafeBytes(of: &align) { pointer -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ])
    }

    /// Wrapped text in `rect`; `maxLines` truncates (by dropping lines).
    static func drawText(_ text: String, font: CTFont, color: CGColor, in rect: CGRect, context: CGContext,
                         alignment: CTTextAlignment, maxLines: Int = 0, verticalCenter: Bool = false) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text, font: font, color: color, alignment: alignment))
        var target = rect
        if verticalCenter {
            let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, rect.size, nil)
            target = CGRect(x: rect.minX, y: rect.midY - fitted.height / 2, width: rect.width, height: ceil(fitted.height))
        }
        if maxLines > 0 {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: 10_000), transform: nil), nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            let string = attributed(text, font: font, color: color, alignment: alignment)
            context.saveGState()
            context.textMatrix = .identity
            let ascent = CTFontGetAscent(font), lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
            for (index, line) in lines.prefix(maxLines).enumerated() {
                var shown = line
                if index == maxLines - 1 && lines.count > maxLines {
                    // The rest of the text on one line, cut with an ellipsis.
                    let start = CTLineGetStringRange(line).location
                    let rest = string.attributedSubstring(from: NSRange(location: start, length: string.length - start))
                    let ellipsis = CTLineCreateWithAttributedString(attributed("…", font: font, color: color, alignment: alignment))
                    shown = CTLineCreateTruncatedLine(CTLineCreateWithAttributedString(rest), Double(rect.width) - 1, .end, ellipsis) ?? line
                }
                let flush: CGFloat = alignment == .right ? 1 : alignment == .center ? 0.5 : 0
                let x = rect.minX + CTLineGetPenOffsetForFlush(shown, flush, Double(rect.width))
                context.textPosition = CGPoint(x: x, y: rect.maxY - ascent - CGFloat(index) * lineHeight)
                CTLineDraw(shown, context)
            }
            context.restoreGState()
            return
        }
        draw(framesetter, in: target, context: context)
    }

    private static func draw(_ framesetter: CTFramesetter, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    // MARK: Images

    /// An image file, scaled down so its longer side is at most `maxPixels`.
    static func loadImage(at url: URL, maxPixels: Int = 2560) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
