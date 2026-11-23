@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Apple's speech recognition, always on-device so nothing leaves the Mac.
public enum AppleTranscriber {
    /// Asks for speech recognition permission once; afterwards returns the answer.
    public static func authorize() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw VoiceError.speechDenied }
    }

    /// The on-device recognizer for a language (empty: the system's).
    @MainActor
    public static func recognizer(language: String) throws -> SFSpeechRecognizer {
        let recognizer = language.isEmpty ? SFSpeechRecognizer() : SFSpeechRecognizer(locale: Locale(identifier: language))
        guard let recognizer else {
            throw VoiceError.appleUnavailable("there's no recognizer for \(language.isEmpty ? Locale.current.identifier : language).")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceError.appleUnavailable(
                "this Mac can't recognize \(recognizer.locale.identifier) offline. Turn on Dictation in System Settings › Keyboard "
                    + "so macOS downloads it, or choose Whisper in Settings › Voice.")
        }
        guard recognizer.isAvailable else {
            throw VoiceError.appleUnavailable("the recognizer is busy or turned off. Try again in a moment.")
        }
        return recognizer
    }

    /// Transcribes a whole audio file.
    @MainActor
    public static func transcribe(file: URL, language: String) async throws -> String {
        try await authorize()
        let recognizer = try recognizer(language: language)
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        let box = ResultBox()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                box.resume(.success(result.bestTranscription.formattedString))
            } else if let error {
                box.resume(.failure(map(error)))
            }
        }
        let text: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { box.set($0) }
        } onCancel: {
            task.cancel()
        }
        let cleaned = TranscriptText.clean(text)
        guard !cleaned.isEmpty else { throw VoiceError.nothingHeard }
        return cleaned
    }

    static func map(_ error: any Error) -> any Error {
        let nsError = error as NSError
        // kAFAssistantErrorDomain 1110: no speech detected; 203: nothing recognized.
        if nsError.domain == "kAFAssistantErrorDomain", [203, 1110].contains(nsError.code) { return VoiceError.nothingHeard }
        if nsError.domain == "kLSRErrorDomain", nsError.code == 301 { return CancellationError() }
        return VoiceError.appleUnavailable(nsError.localizedDescription)
    }
}

/// A continuation that may be resumed from several callbacks but only once.
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var pending: Result<String, any Error>?
    private var done = false

    func set(_ continuation: CheckedContinuation<String, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let pending {
            continuation.resume(with: pending)
            done = true
        } else {
            self.continuation = continuation
        }
    }

    func resume(_ result: Result<String, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        if let continuation {
            continuation.resume(with: result)
            self.continuation = nil
            done = true
        } else if pending == nil {
            pending = result
        }
    }
}
