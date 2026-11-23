@preconcurrency import AVFoundation
import Foundation
import SlateCore

public enum AnimaticError: Error, LocalizedError, Equatable {
    case empty
    case cannotExport(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "There's nothing to play: the script has no scenes with IDs."
        case .cannotExport(let reason): "Couldn't export the animatic: \(reason)"
        }
    }
}

/// An animatic ready to play or export: the composition, how to draw it and how loud.
public final class AnimaticComposition: @unchecked Sendable {
    public let timeline: AnimaticTimeline
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    /// Media files (from the project root) that couldn't be read.
    public let missing: [String]

    init(timeline: AnimaticTimeline, composition: AVComposition, videoComposition: AVVideoComposition,
         audioMix: AVAudioMix, missing: [String]) {
        self.timeline = timeline
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.missing = missing
    }

    public var duration: Double { composition.duration.seconds }

    @MainActor
    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

/// Builds an `AVComposition` from an `AnimaticTimeline`.
///
/// Clips go straight into the video track. Stills and placeholders need a
/// source too, so a one-second black movie (made once, in `.slate/cache/`) is
/// stretched over each; the custom compositor then draws the picture.
public enum AnimaticComposer {
    public static let renderSize = CGSize(width: 1920, height: 1080)
    static let timescale: CMTimeScale = 600

    public static func compose(_ timeline: AnimaticTimeline, root: URL, overlays: AnimaticOverlays = .none,
                               renderSize: CGSize = renderSize) async throws -> AnimaticComposition {
        guard !timeline.segments.isEmpty, timeline.duration > 0 else { throw AnimaticError.empty }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AnimaticError.cannotExport("no video track")
        }
        // Assets must stay alive until their tracks are inserted.
        var assets: [AVAsset] = []
        defer { withExtendedLifetime(assets) {} }
        let blank = AVURLAsset(url: try await BlankMovie.url(in: root))
        assets.append(blank)
        guard let blankTrack = try await blank.loadTracks(withMediaType: .video).first else {
            throw AnimaticError.cannotExport("the blank track couldn't be made")
        }
        let blankRange = try await blankTrack.load(.timeRange)

        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }
        func fillBlank(_ range: CMTimeRange) throws {
            try video.insertTimeRange(blankRange, of: blankTrack, at: range.start)
            video.scaleTimeRange(CMTimeRange(start: range.start, duration: blankRange.duration), toDuration: range.duration)
        }

        var instructions: [AnimaticInstruction] = []
        var missing: [String] = []
        var clipAudio: AVMutableCompositionTrack?
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        let segments = timeline.segments

        for (index, segment) in segments.enumerated() {
            let start = time(segment.start)
            let end = index + 1 < segments.count ? time(segments[index + 1].start) : time(timeline.duration)
            let range = CMTimeRange(start: start, end: end)
            guard range.duration > .zero else { continue }
            func instruction(_ range: CMTimeRange, _ picture: AnimaticInstruction.Picture) -> AnimaticInstruction {
                AnimaticInstruction(timeRange: range, picture: picture, segment: segment, guide: timeline.guide,
                                    overlays: overlays, cues: timeline.subtitles)
            }
            switch segment.content {
            case .placeholder(let text):
                try fillBlank(range)
                instructions.append(instruction(range, .placeholder(text)))

            case .image(let path):
                let image = (try? url(path, root)).flatMap { AnimaticPainter.loadImage(at: $0) }
                if image == nil { missing.append(path) }
                try fillBlank(range)
                instructions.append(instruction(range, .still(image)))

            case .clip(let path, let inPoint, let audio):
                let asset = try? url(path, root).map { AVURLAsset(url: $0) }
                if let asset { assets.append(asset) }
                guard let asset, let source = try? await asset.loadTracks(withMediaType: .video).first,
                      let length = try? await asset.load(.duration) else {
                    missing.append(path)
                    try fillBlank(range)
                    instructions.append(instruction(range, .still(nil)))
                    continue
                }
                let from = min(time(inPoint), length)
                let played = CMTimeMinimum(range.duration, length - from)
                var clipEnd = start
                if played > .zero {
                    try video.insertTimeRange(CMTimeRange(start: from, duration: played), of: source, at: start)
                    let transform = (try? await source.load(.preferredTransform)) ?? .identity
                    instructions.append(instruction(CMTimeRange(start: start, duration: played), .clip(trackID: video.trackID, transform: transform)))
                    clipEnd = start + played
                    if audio, let sound = try? await asset.loadTracks(withMediaType: .audio).first {
                        if clipAudio == nil {
                            clipAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        try? clipAudio?.insertTimeRange(CMTimeRange(start: from, duration: played), of: sound, at: start)
                    }
                }
                // A clip shorter than its time holds its last frame.
                if clipEnd < end {
                    let rest = CMTimeRange(start: clipEnd, end: end)
                    try fillBlank(rest)
                    let last = await lastFrame(of: asset, at: from + played)
                    instructions.append(instruction(rest, .still(last)))
                }
            }
        }

        // Scratch audio and the temp score: a track each, volumes set per placement.
        var tracks: [AudioPlacement.Kind: AVMutableCompositionTrack] = [:]
        var parameters: [AudioPlacement.Kind: AVMutableAudioMixInputParameters] = [:]
        for placement in timeline.audio {
            // The asset must outlive the insert: a track only weakly holds its asset.
            let asset = (try? url(placement.path, root)).map { AVURLAsset(url: $0) }
            guard let asset, let sound = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await sound.load(.timeRange).duration else {
                missing.append(placement.path)
                continue
            }
            let offset = time(placement.offset)
            guard offset < length else { continue }
            let duration = CMTimeMinimum(time(placement.duration), length - offset)
            if tracks[placement.kind] == nil {
                tracks[placement.kind] = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                parameters[placement.kind] = tracks[placement.kind].map { AVMutableAudioMixInputParameters(track: $0) }
            }
            do {
                try tracks[placement.kind]?.insertTimeRange(CMTimeRange(start: offset, duration: duration), of: sound, at: time(placement.start))
                parameters[placement.kind]?.setVolume(Float(placement.volume), at: time(placement.start))
            } catch {
                missing.append(placement.path)
            }
            withExtendedLifetime(asset) {}
        }
        audioParameters += parameters.values
        if let clipAudio { audioParameters.append(AVMutableAudioMixInputParameters(track: clipAudio)) }
        // An empty track stops an export, so drop any that got nothing.
        for track in composition.tracks where track.segments.isEmpty {
            audioParameters.removeAll { $0.trackID == track.trackID }
            composition.removeTrack(track)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = AnimaticCompositor.self
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = renderSize
        videoComposition.instructions = instructions
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParameters
        return AnimaticComposition(timeline: timeline, composition: composition, videoComposition: videoComposition,
                                   audioMix: mix, missing: Array(Set(missing)).sorted())
    }

    /// A file in the project, or nil if it isn't there.
    private static func url(_ path: String, _ root: URL) throws -> URL? {
        let url = root.appending(path: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A clip's frame just before `time`.
    static func lastFrame(of asset: AVAsset, at time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        let at = CMTimeMaximum(.zero, time - CMTime(value: 1, timescale: 30))
        return try? await generator.image(at: at).image
    }

    /// A clip's poster frame at `seconds`.
    public static func poster(of url: URL, at seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

/// A one-second black movie that stills are stretched over. Rebuildable, so it lives in `.slate/cache/`.
enum BlankMovie {
    static let name = "animatic-blank.mov"

    static func url(in root: URL) async throws -> URL {
        let folder = root.appending(path: ProjectLayout.cache + "/cache", directoryHint: .isDirectory)
        let url = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appending(path: UUID().uuidString + ".mov")
        try await write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        return url
    }

    static func write(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AnimaticError.cannotExport("blank movie") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? AnimaticError.cannotExport("blank movie") }
    }
}
