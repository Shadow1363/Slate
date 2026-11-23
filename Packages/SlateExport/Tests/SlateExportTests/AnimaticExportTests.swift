@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import SlateCore
@testable import SlateExport

/// Makes test media: a solid PNG, a 2-second clip and a tone.
enum TestMedia {
    static func png(_ color: CGColor, width: Int = 320, height: Int = 180) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A green 2-second clip, 10 fps.
    static func clip(to url: URL, seconds: Int = 2) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: CVPixelBufferGetDataSize(buffer!), by: 4) {
                base[offset] = 0; base[offset + 1] = 200; base[offset + 2] = 0; base[offset + 3] = 255 // BGRA green
            }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
    }

    /// A quiet sine tone as linear PCM in a `.caf`.
    static func tone(to url: URL, seconds: Double = 5) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 220 / 44_100) * 0.2)
        }
        try file.write(from: buffer)
    }
}

@Suite("Animatic export", .serialized)
struct AnimaticExportTests {
    static let script = """
    INT. KITCHEN - NIGHT {#s001 dur=0:02}

    Rain hammers the window.

    MARA
    I haven't opened it yet.

    EXT. ROOF - DAWN {#s002 dur=0:01}

    Wind.
    """

    static let folder = "storyboard/scenes/s001 int-kitchen-night"

    /// A project folder with a red still, a green clip held past its end, scratch audio and a score.
    static func project() async throws -> (TempDirectory, AnimaticTimeline) {
        let temp = try TempDirectory()
        let root = temp.url
        let folderURL = root.appending(path: folder)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try png(CGColor(red: 1, green: 0, blue: 0, alpha: 1)).write(to: folderURL.appending(path: "01.png"))
        try await TestMedia.clip(to: folderURL.appending(path: "02.mov"))
        try TestMedia.tone(to: folderURL.appending(path: "scratch.caf"))
        try TestMedia.tone(to: root.appending(path: "storyboard/score.caf"))

        var frames = FramesFile(scene: "s001")
        var still = StoryboardFrame(file: "01.png")
        still.duration = 1
        still.caption = "Rain"
        var clip = StoryboardFrame(file: "02.mov")
        clip.inPoint = 1
        clip.duration = 1.5 // only 1 s of clip is left after `in`
        frames.frames = [still, clip]
        frames.scratchAudio = "scratch.caf"
        frames.scratchVolume = 0.5
        var settings = StoryboardSettings()
        settings.score = "score.caf"
        settings.guide = .scope

        let book = ScriptBook(texts: [(path: "script/script.md", text: script)])
        let scenes = AnimaticScene.all(in: book, boards: ["s001": (folder, frames)])
        return (temp, AnimaticTimeline.build(scenes: scenes, settings: settings))
    }

    static func png(_ color: CGColor) -> Data { TestMedia.png(color) }

    /// The colour at the centre of the composed frame at `seconds`.
    static func centre(of composed: AnimaticComposition, at seconds: Double) async throws -> (r: Int, g: Int, b: Int) {
        let generator = AVAssetImageGenerator(asset: composed.composition)
        generator.videoComposition = composed.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2), width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    @Test func compositionMatchesTheTimeline() async throws {
        let (temp, timeline) = try await Self.project()
        #expect(timeline.duration == 3.5)
        let composed = try await AnimaticComposer.compose(timeline, root: temp.url)
        #expect(abs(composed.duration - 3.5) < 0.01)
        #expect(composed.missing.isEmpty)
        #expect(composed.composition.tracks(withMediaType: .video).count == 1)
        // Scratch and score (the generated clip has no sound).
        #expect(composed.composition.tracks(withMediaType: .audio).count == 2)
        #expect(composed.videoComposition.instructions.count == 4) // still, clip, held last frame, placeholder
        #expect(composed.videoComposition.renderSize == CGSize(width: 1920, height: 1080))
        // The blank track is cached in .slate/cache.
        #expect(FileManager.default.fileExists(atPath: temp.url.appending(path: ".slate/cache/animatic-blank.mov").path))

        let red = try await Self.centre(of: composed, at: 0.5)
        #expect(red.r > 200 && red.g < 40)
        let green = try await Self.centre(of: composed, at: 1.5)
        #expect(green.g > 150 && green.r < 100, "\(green)")
        let held = try await Self.centre(of: composed, at: 2.3)
        #expect(held.g > 150)
        let card = try await Self.centre(of: composed, at: 3.2)
        #expect(card.r < 120 && card.r == card.g) // a grey placeholder card
    }

    @Test func missingMediaIsReportedNotFatal() async throws {
        let (temp, timeline) = try await Self.project()
        try FileManager.default.removeItem(at: temp.url.appending(path: Self.folder + "/01.png"))
        try FileManager.default.removeItem(at: temp.url.appending(path: "storyboard/score.caf"))
        let composed = try await AnimaticComposer.compose(timeline, root: temp.url)
        #expect(composed.missing == ["storyboard/score.caf", Self.folder + "/01.png"].sorted())
        #expect(abs(composed.duration - 3.5) < 0.01)
    }

    @Test func emptyTimelineThrows() async throws {
        let temp = try TempDirectory()
        await #expect(throws: AnimaticError.empty) {
            _ = try await AnimaticComposer.compose(AnimaticTimeline(), root: temp.url)
        }
    }

    @Test func exportsAPlayableMovie() async throws {
        let (temp, timeline) = try await Self.project()
        let url = AnimaticExporter.destination(projectName: "Test", projectRoot: temp.url)
        #expect(url.lastPathComponent.hasSuffix(".mov"))
        try await AnimaticExporter.export(timeline, root: temp.url, overlays: AnimaticOverlays(), to: url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3.5) < 0.1)
        let video = try await asset.loadTracks(withMediaType: .video)
        #expect(video.count == 1)
        #expect(try await video[0].load(.naturalSize) == CGSize(width: 1920, height: 1080))
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func boardsPDFPages() async throws {
        let (temp, timeline) = try await Self.project()
        // Three segments: the still, the clip and the empty scene's card.
        for (layout, pages) in [(BoardsPDF.Layout.two, 2), (.four, 1), (.six, 1)] {
            let boards = BoardsPDF(timeline: timeline, projectName: "Test", layout: layout)
            #expect(boards.pageCount == pages)
            let data = await boards.render(root: temp.url)
            let document = try #require(PDFDocument(data: data))
            #expect(document.pageCount == pages)
            #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612))
            let text = document.string ?? ""
            #expect(text.contains("INT. KITCHEN - NIGHT"))
            #expect(text.contains("Test — Storyboard"))
        }
        let a4 = BoardsPDF(timeline: timeline, projectName: "Test", layout: .six, pageSize: .a4)
        let document = try #require(PDFDocument(data: await a4.render(root: temp.url)))
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 842, height: 595))
        #expect(document.string?.contains("Rain") == true)
        #expect(BoardsPDF.destination(projectName: "Test", projectRoot: temp.url).lastPathComponent.contains("Test – Boards – "))
    }
}

/// A temp folder removed when released.
final class TempDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "SlateAnimatic-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url.appending(path: "storyboard"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
