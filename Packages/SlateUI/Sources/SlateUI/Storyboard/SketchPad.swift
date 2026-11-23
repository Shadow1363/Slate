import AppKit
import SlateCore
import SwiftUI

/// Draws sketch strokes. The canvas is always 16:9; the guide marks the frame
/// inside it, and a saved sketch is cropped to that frame.
enum SketchRenderer {
    static let canvasRatio = 16.0 / 9.0
    static let greys: [Double] = [0.1, 0.35, 0.6, 0.85]
    /// Pen widths as a share of the canvas width.
    static let widths: [Double] = [0.002, 0.005, 0.012]

    /// The guide's frame inside a canvas of `size`.
    static func guideRect(_ guide: SketchGuide, in size: CGSize) -> CGRect {
        let height = min(size.height, size.width / guide.ratio)
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }

    /// Strokes over a white page. `context` is top-left origin (flipped).
    static func draw(_ strokes: [SketchStrokes.Stroke], in context: CGContext, size: CGSize) {
        context.setFillColor(.white)
        context.fill(CGRect(origin: .zero, size: size))
        // Erasing clears this layer back to the page.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            context.setBlendMode(stroke.erase ? .clear : .normal)
            let grey = CGFloat(stroke.grey)
            context.setStrokeColor(CGColor(gray: grey, alpha: 1))
            context.setFillColor(CGColor(gray: grey, alpha: 1))
            let points = stroke.points.compactMap { p -> (CGPoint, Double)? in
                guard p.count >= 2 else { return nil }
                return (CGPoint(x: p[0] * size.width, y: p[1] * size.height), p.count > 2 ? p[2] : 1)
            }
            let base = stroke.width * size.width
            if points.count == 1, let (point, pressure) = points.first {
                let r = width(base, pressure, erase: stroke.erase) / 2
                context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
                continue
            }
            for (a, b) in zip(points, points.dropFirst()) {
                context.setLineWidth(width(base, (a.1 + b.1) / 2, erase: stroke.erase))
                context.move(to: a.0)
                context.addLine(to: b.0)
                context.strokePath()
            }
        }
        context.setBlendMode(.normal)
        context.endTransparencyLayer()
    }

    private static func width(_ base: Double, _ pressure: Double, erase: Bool) -> CGFloat {
        erase ? base * 3 : base * (0.35 + 0.65 * min(max(pressure, 0), 1))
    }

    /// The sketch as PNG, cropped to its guide, `pixelWidth` wide.
    static func png(_ sketch: SketchStrokes, pixelWidth: Int = 1920) -> Data? {
        let canvas = CGSize(width: pixelWidth, height: Int((Double(pixelWidth) / canvasRatio).rounded()))
        // Whole pixels, centred: 1920 × 803 for 2.39:1.
        let height = min(canvas.height, (canvas.width / sketch.guide.ratio).rounded())
        let crop = CGRect(x: 0, y: ((canvas.height - height) / 2).rounded(), width: canvas.width, height: height)
        guard let context = CGContext(data: nil, width: Int(crop.width), height: Int(crop.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Flip to top-left origin, then shift so the guide's frame fills the image.
        context.translateBy(x: 0, y: crop.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        draw(sketch.strokes, in: context, size: canvas)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// The drawing surface: mouse, trackpad (Force Touch) or tablet, with pressure.
final class SketchCanvasView: NSView {
    var strokes: [SketchStrokes.Stroke] = [] { didSet { needsDisplay = true } }
    var guide: SketchGuide = .wide { didSet { needsDisplay = true } }
    var grey = SketchRenderer.greys[0]
    var width = SketchRenderer.widths[1]
    var erasing = false
    var onStroke: ((SketchStrokes.Stroke) -> Void)?
    private var current: SketchStrokes.Stroke?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ event: NSEvent) -> [Double] {
        let p = convert(event.locationInWindow, from: nil)
        // A mouse reports pressure 1 while down; a trackpad or tablet reports real pressure.
        let pressure = event.pressure > 0 ? Double(event.pressure) : 1
        return [min(max(p.x / bounds.width, 0), 1), min(max(p.y / bounds.height, 0), 1), pressure]
    }

    override func mouseDown(with event: NSEvent) {
        current = SketchStrokes.Stroke(grey: grey, width: width, erase: erasing, points: [point(event)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current?.points.append(point(event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let stroke = current else { return }
        current = nil
        onStroke?(stroke)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        SketchRenderer.draw(strokes + (current.map { [$0] } ?? []), in: context, size: bounds.size)
        // Darken outside the guide's frame.
        let frame = SketchRenderer.guideRect(guide, in: bounds.size)
        context.setFillColor(CGColor(gray: 0, alpha: 0.35))
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: frame.minY))
        context.fill(CGRect(x: 0, y: frame.maxY, width: bounds.width, height: bounds.height - frame.maxY))
        context.setStrokeColor(CGColor(gray: 0.5, alpha: 0.8))
        context.setLineWidth(1)
        context.stroke(frame.insetBy(dx: 0.5, dy: 0.5))
    }
}

private struct SketchCanvas: NSViewRepresentable {
    let strokes: [SketchStrokes.Stroke]
    let guide: SketchGuide
    let grey: Double
    let width: Double
    let erasing: Bool
    let onStroke: (SketchStrokes.Stroke) -> Void

    func makeNSView(context: Context) -> SketchCanvasView { SketchCanvasView() }

    func updateNSView(_ view: SketchCanvasView, context: Context) {
        if view.strokes != strokes { view.strokes = strokes }
        if view.guide != guide { view.guide = guide }
        view.grey = grey
        view.width = width
        view.erasing = erasing
        view.onStroke = onStroke
    }
}

/// The sketch pad sheet: pen, eraser, four greys, three sizes, frame guides, undo.
struct SketchPadSheet: View {
    let model: StoryboardModel
    let target: StoryboardModel.SketchTarget
    @State private var strokes: [SketchStrokes.Stroke] = []
    @State private var redo: [[SketchStrokes.Stroke]] = []
    @State private var history: [[SketchStrokes.Stroke]] = []
    @State private var guide: SketchGuide = .wide
    @State private var grey = 0
    @State private var size = 1
    @State private var erasing = false
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Picker("Tool", selection: $erasing) {
                    Label("Pen", systemImage: "pencil.tip").tag(false)
                    Label("Eraser", systemImage: "eraser").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                HStack(spacing: 6) {
                    ForEach(SketchRenderer.greys.indices, id: \.self) { index in
                        Circle()
                            .fill(Color(white: SketchRenderer.greys[index]))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: grey == index && !erasing ? 2 : 0).padding(-3))
                            .onTapGesture { grey = index; erasing = false }
                            .accessibilityLabel("Grey \(index + 1)")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                Picker("Size", selection: $size) {
                    Text("Fine").tag(0)
                    Text("Medium").tag(1)
                    Text("Bold").tag(2)
                }
                .fixedSize()
                Picker("Guide", selection: $guide) {
                    ForEach(SketchGuide.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Spacer()
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(history.isEmpty)
                    .help("Undo stroke")
                Button { redoStroke() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(redo.isEmpty)
                    .help("Redo stroke")
                Button("Clear") { record(); strokes = [] }
                    .disabled(strokes.isEmpty)
            }
            SketchCanvas(strokes: strokes, guide: guide, grey: SketchRenderer.greys[grey], width: SketchRenderer.widths[size],
                         erasing: erasing) { stroke in
                record()
                strokes.append(stroke)
            }
            .aspectRatio(SketchRenderer.canvasRatio, contentMode: .fit)
            .frame(minWidth: 720, minHeight: 405)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(radius: 2)
            HStack {
                Text("Draw with a mouse, trackpad or tablet; pressure changes the line. Saved as a PNG with its strokes, so you can edit it again.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.file == nil ? "Add Sketch" : "Save Sketch") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(strokes.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 760)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let file = target.file, let folder = model.plan.boarded[target.sceneID]?.path,
           let existing = model.strokes(for: FrameRef(folder: folder, file: file)) {
            strokes = existing.strokes
            guide = existing.guide
        } else {
            guide = model.defaultGuide
        }
    }

    private func record() {
        history.append(strokes)
        redo = []
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        redo.append(strokes)
        strokes = previous
    }

    private func redoStroke() {
        guard let next = redo.popLast() else { return }
        history.append(strokes)
        strokes = next
    }

    private func save() {
        let sketch = SketchStrokes(guide: guide, strokes: strokes)
        guard let png = SketchRenderer.png(sketch) else { return }
        model.saveSketch(sketch, png: png, target: target)
        dismiss()
    }
}
