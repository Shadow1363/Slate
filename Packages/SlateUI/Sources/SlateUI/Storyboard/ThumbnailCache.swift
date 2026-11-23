import AVFoundation
import AppKit
import ImageIO
import Observation

/// Small images of frames: image thumbnails, and poster frames and lengths
/// for clips (read in the background). Kept in memory only; always rebuildable.
@MainActor
@Observable
final class ThumbnailCache {
    private(set) var images: [String: NSImage] = [:]
    private(set) var lengths: [String: Double] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var stamps: [String: Date] = [:]

    static let maxPixels = 480

    /// A thumbnail for a file (project-relative `path` at `url`); nil until it's ready.
    func thumbnail(for path: String, url: URL?, at time: Double? = nil) -> NSImage? {
        guard let url else { return nil }
        let key = time.map { path + "@" + String(format: "%.1f", $0) } ?? path
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if stamps[key] != modified {
            stamps[key] = modified
            images[key] = nil
        }
        if let image = images[key] { return image }
        guard !loading.contains(key) else { return nil }
        if StoryboardMediaKind.isClip(url) {
            loading.insert(key)
            Task { await loadClip(url: url, key: key, path: path, time: time) }
            return nil
        }
        let image = Self.imageThumbnail(url)
        images[key] = image
        return image
    }

    /// The full length of a clip, once its poster has loaded.
    func clipLength(for path: String) -> Double? { lengths[path] }

    func forget(_ path: String) {
        for key in images.keys where key == path || key.hasPrefix(path + "@") {
            images[key] = nil
            stamps[key] = nil
        }
    }

    private func loadClip(url: URL, key: String, path: String, time: Double?) async {
        defer { loading.remove(key) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.maxPixels, height: Self.maxPixels)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            lengths[path] = duration.seconds
        }
        let at = CMTime(seconds: time ?? 0, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: at).image {
            images[key] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    /// A downscaled image, read without decoding the whole file.
    static func imageThumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

enum StoryboardMediaKind {
    static func isClip(_ url: URL) -> Bool {
        ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
    }
}
