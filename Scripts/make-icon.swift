#!/usr/bin/env swift
// Draws Slate's app icon (a film slate on a deep-blue macOS rounded square)
// and writes App/Assets.xcassets/AppIcon.appiconset with every size macOS uses.
// Run from the repo root: `swift Scripts/make-icon.swift`
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "App/Assets.xcassets/AppIcon.appiconset")
let catalog = root.appending(path: "App/Assets.xcassets")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The artwork at 1024 × 1024, in Apple's icon grid (an 824 pt body with a soft shadow).
func draw(in context: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    context.clear(canvas)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Background: deep blue, lighter at the top, with a drop shadow.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x13233F))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x2C4F86), color(0x11203B)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()

    // The slate's board.
    let board = CGRect(x: 230, y: 190, width: 564, height: 400)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.4))
    context.addPath(CGPath(roundedRect: board, cornerWidth: 34, cornerHeight: 34, transform: nil))
    context.setFillColor(color(0x1B1E24))
    context.fillPath()
    context.restoreGState()

    // Chalk lines: scene, take, roll.
    context.setStrokeColor(color(0xE9E4D8, 0.85))
    context.setLineWidth(10)
    context.setLineCap(.round)
    for (y, width) in [(500.0, 380.0), (420.0, 300.0), (340.0, 340.0), (260.0, 220.0)] {
        context.move(to: CGPoint(x: 290, y: y))
        context.addLine(to: CGPoint(x: 290 + width, y: y))
    }
    context.strokePath()

    // The clapper: a striped bar hinged at the left, lifted a little.
    func stripedBar(_ rect: CGRect, angle: CGFloat, pivot: CGPoint) {
        context.saveGState()
        context.translateBy(x: pivot.x, y: pivot.y)
        context.rotate(by: angle)
        context.translateBy(x: -pivot.x, y: -pivot.y)
        let path = CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.35))
        context.addPath(path)
        context.setFillColor(color(0xF5F2EA))
        context.fillPath()
        context.restoreGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(color(0x1B1E24))
        var x = rect.minX - rect.height
        while x < rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x + 60, y: rect.minY))
            context.addLine(to: CGPoint(x: x + 60 + rect.height, y: rect.maxY))
            context.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            context.closePath()
            x += 120
        }
        context.fillPath()
        context.restoreGState()
    }
    stripedBar(CGRect(x: 230, y: 600, width: 564, height: 96), angle: 0, pivot: CGPoint(x: 250, y: 600))
    stripedBar(CGRect(x: 230, y: 712, width: 564, height: 96), angle: 0.14, pivot: CGPoint(x: 250, y: 712))

    // Hinge.
    context.setFillColor(color(0xF2B84B))
    context.fillEllipse(in: CGRect(x: 226, y: 674, width: 52, height: 52))
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.interpolationQuality = .high
    draw(in: context)
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(size: points * scale).write(to: iconset.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "make-icon.swift"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: iconset.appending(path: "Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["version": 1, "author": "make-icon.swift"]], options: [.prettyPrinted]).write(to: catalog.appending(path: "Contents.json"))
print("Wrote \(iconset.path)")
