import Foundation
import whisper

/// Runs whisper.cpp on its own thread. The last model used stays loaded so
/// the next dictation starts quickly.
public final class WhisperTranscriber: @unchecked Sendable {
    public static let shared = WhisperTranscriber()

    private let queue = DispatchQueue(label: "app.slate.whisper", qos: .userInitiated)
    // Only touched on `queue`.
    private var context: OpaquePointer?
    private var loadedPath: String?

    private init() {
        whisper_log_set({ _, _, _ in }, nil)
    }

    deinit {
        if let context { whisper_free(context) }
    }

    /// Frees the loaded model. Call before the app quits: ggml's Metal
    /// backend aborts if a model is still loaded when the process exits.
    public func unload() {
        queue.sync {
            if let context { whisper_free(context) }
            context = nil
            loadedPath = nil
        }
    }

    public func transcribe(_ samples: [Float], model: WhisperModel, language: String?) async throws -> String {
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
        if loadedPath != modelPath {
            if let context { whisper_free(context) }
            context = nil
            loadedPath = nil
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            guard let loaded = whisper_init_from_file_with_params(modelPath, params) else {
                throw VoiceError.whisperFailed("the model file couldn't be loaded. Delete it and download it again in Settings › Voice.")
            }
            context = loaded
            loadedPath = modelPath
        }
        guard let context else { throw VoiceError.whisperFailed("no model loaded") }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_timestamps = true
        params.suppress_blank = true
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        let status = language.withCString { languagePointer in
            params.language = languagePointer
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard status == 0 else { throw VoiceError.whisperFailed("whisper_full returned \(status)") }

        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, index) {
                text += String(cString: segment)
            }
        }
        let cleaned = TranscriptText.clean(text)
        guard !cleaned.isEmpty else { throw VoiceError.nothingHeard }
        return cleaned
    }
}
