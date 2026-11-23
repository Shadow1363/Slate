@preconcurrency import AVFoundation
import CoreImage
import Foundation
import SlateCore

/// What one stretch of the video shows. Each segment of the timeline becomes
/// one instruction (a clip shorter than its time adds a second one that holds
/// its last frame).
final class AnimaticInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    enum Picture {
        case still(CGImage?)
        case clip(trackID: CMPersistentTrackID, transform: CGAffineTransform)
        case placeholder(String)
    }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let picture: Picture
    let segment: AnimaticSegment
    let guide: SketchGuide
    /// Burned-in overlays (export only; the player draws its own).
    let overlays: AnimaticOverlays
    let cues: [SubtitleCue]

    init(timeRange: CMTimeRange, picture: Picture, segment: AnimaticSegment, guide: SketchGuide,
         overlays: AnimaticOverlays, cues: [SubtitleCue]) {
        self.timeRange = timeRange
        self.picture = picture
        self.segment = segment
        self.guide = guide
        self.overlays = overlays
        self.cues = cues
        if case .clip(let trackID, _) = picture {
            requiredSourceTrackIDs = [NSNumber(value: trackID)]
        } else {
            requiredSourceTrackIDs = []
        }
    }
}

/// Draws every frame of the animatic: stills (with push-in or pull-out),
/// clip frames, placeholder cards, letterboxed to the storyboard guide.
final class AnimaticCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let format = kCVPixelFormatType_32BGRA
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.format]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.format]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? AnimaticInstruction,
              let buffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "Slate.Animatic", code: 1))
            return
        }
        let time = request.compositionTime.seconds
        var clipImage: CGImage?
        if case .clip(let trackID, let transform) = instruction.picture,
           let source = request.sourceFrame(byTrackID: trackID) {
            var image = CIImage(cvPixelBuffer: source)
            if transform != .identity {
                image = image.transformed(by: transform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            }
            clipImage = ciContext.createCGImage(image, from: image.extent)
        }
        render(instruction, time: time, clip: clipImage, into: buffer)
        request.finish(withComposedVideoFrame: buffer)
    }

    private func render(_ instruction: AnimaticInstruction, time: Double, clip: CGImage?, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        let size = CGSize(width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let rect = AnimaticPainter.guideRect(instruction.guide, in: size)
        let segment = instruction.segment
        switch instruction.picture {
        case .still(let image):
            if let image {
                let progress = segment.duration > 0 ? (time - segment.start) / segment.duration : 0
                AnimaticPainter.draw(image, in: context, rect: rect, scale: segment.motion.scale(at: progress))
            } else {
                AnimaticPainter.drawPlaceholder(number: segment.sceneNumber, heading: segment.heading,
                                                text: "Missing: " + (segment.file ?? ""), in: context, rect: rect)
            }
        case .clip:
            if let clip { AnimaticPainter.draw(clip, in: context, rect: rect) }
        case .placeholder(let text):
            AnimaticPainter.drawPlaceholder(number: segment.sceneNumber, heading: segment.heading, text: text, in: context, rect: rect)
        }
        if !instruction.overlays.isEmpty {
            let cue = instruction.cues.last { $0.start <= time && time < $0.end }
            AnimaticPainter.drawOverlays(instruction.overlays, segment: segment, cue: cue, in: context, size: size)
        }
    }
}
