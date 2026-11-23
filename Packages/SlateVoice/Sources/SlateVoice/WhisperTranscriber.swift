import Foundation
import CWhisper

/// Runs whisper.cpp on its own thread. The last model used stays loaded so
/// the next dictation starts quickly.
public final class WhisperTranscriber: @unchecked Sendable {
    public static let shared = WhisperTranscriber()

    private let queue = DispatchQueue(label: "app.slate.whisper", qos: .userInitiated)
    // Only touched on `queue`.
    private var context: UnsafeMutableRawPointer?
    private var loadedPath: String?

    /// Where the framework is opened from; tests point it at Vendor/.
    nonisolated(unsafe) static var frameworkBinary: URL = WhisperEngine.binaryURL

    private init() {}

    deinit {
        if let context { slate_whisper_free(context) }
    }

    /// Frees the loaded model. Call before the app quits: ggml's Metal
    /// backend aborts if a model is still loaded when the process exits.
    public func unload() {
        queue.sync {
            if let context { slate_whisper_free(context) }
            context = nil
            loadedPath = nil
        }
    }

    public func transcribe(_ samples: [Float], model: WhisperModel, language: String?) async throws -> String {
        guard WhisperEngine.isInstalled else { throw VoiceError.whisperNotInstalled }
        guard model.isDownloaded else { throw VoiceError.whisperModelMissing(model.title) }
        guard !samples.isEmpty else { throw VoiceError.nothingHeard }
        return try await transcribe(samples, modelPath: model.localURL.path,
                                    language: model.isEnglishOnly ? "en" : (language ?? "auto"))
    }

    /// With a model file anywhere (tests use a small one).
    func transcribe(_ samples: [Float], modelPath: String, language: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.run(samples, modelPath: modelPath, language: language))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func transcribe(file: URL, model: WhisperModel, language: String?) async throws -> String {
        let samples = try await Task.detached(priority: .userInitiated) { try AudioSamples.load(file) }.value
        return try await transcribe(samples, model: model, language: language)
    }

    private func run(_ samples: [Float], modelPath: String, language: String) throws -> String {
        if !slate_whisper_is_loaded() {
            var error = [CChar](repeating: 0, count: 512)
            guard slate_whisper_load(Self.frameworkBinary.path, &error, error.count) == 0 else {
                let reason = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                throw VoiceError.whisperFailed("the Whisper engine couldn't be opened (\(reason)). Remove it in Settings › Voice and download it again.")
            }
        }
        if loadedPath != modelPath {
            if let context { slate_whisper_free(context) }
            context = nil
            loadedPath = nil
            guard let loaded = slate_whisper_init(modelPath, true) else {
                throw VoiceError.whisperFailed("the model file couldn't be loaded. Delete it and download it again in Settings › Voice.")
            }
            context = loaded
            loadedPath = modelPath
        }
        guard let context else { throw VoiceError.whisperFailed("no model loaded") }
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        let status = samples.withUnsafeBufferPointer { buffer in
            slate_whisper_run(context, buffer.baseAddress, Int32(buffer.count), language, threads)
        }
        guard status == 0 else { throw VoiceError.whisperFailed("whisper_full returned \(status)") }
        var text = ""
        for index in 0..<slate_whisper_segment_count(context) {
            if let segment = slate_whisper_segment_text(context, index) {
                text += String(cString: segment)
            }
        }
        let cleaned = TranscriptText.clean(text)
        guard !cleaned.isEmpty else { throw VoiceError.nothingHeard }
        return cleaned
    }
}
