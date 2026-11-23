@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// One dictation: listen to the microphone, then hand back the words.
///
/// With Apple the words appear as you speak (`partial`); Whisper and OpenAI
/// record first and transcribe when you stop.
@MainActor
@Observable
public final class Dictation {
    public enum Phase: Equatable {
        case starting
        case listening
        case transcribing
        case failed(String)
    }

    public private(set) var phase: Phase = .starting
    /// What Apple has heard so far.
    public private(set) var partial = ""
    /// Microphone loudness, 0…1.
    public private(set) var level: Float = 0
    public private(set) var elapsed: TimeInterval = 0
    public let settings: VoiceSettings

    private let engine = AVAudioEngine()
    private let recorder = Recorder()
    private var appleRequest: SFSpeechAudioBufferRecognitionRequest?
    private var appleTask: SFSpeechRecognitionTask?
    private var appleFinal: ResultBox?
    private var started: Date?
    private var clock: Timer?

    public init(settings: VoiceSettings = .current()) {
        self.settings = settings
    }

    /// Asks for permission if needed and starts listening.
    public func start() async {
        do {
            try await Self.authorizeMicrophone()
            if settings.engine == .apple {
                try await AppleTranscriber.authorize()
                try startApple()
            } else {
                try check()
            }
            try startEngine()
            phase = .listening
            started = .now
            clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let started = self.started else { return }
                    self.elapsed = Date.now.timeIntervalSince(started)
                    self.level = self.recorder.level
                }
            }
        } catch {
            teardown()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops listening and returns the transcript (nil if cancelled or failed;
    /// `phase` then says why).
    public func finish() async -> String? {
        guard phase == .listening else { return nil }
        stopEngine()
        phase = .transcribing
        do {
            let text: String
            switch settings.engine {
            case .apple:
                appleRequest?.endAudio()
                text = try await waitForApple()
            case .whisper:
                text = try await WhisperTranscriber.shared.transcribe(recorder.takeSamples(), model: settings.whisperModel,
                                                                      language: settings.isoLanguage)
            case .openAI:
                text = try await OpenAITranscriber(model: settings.openAIModel, language: settings.isoLanguage)
                    .transcribe(recorder.takeSamples())
            }
            teardown()
            return text
        } catch is CancellationError {
            teardown()
            return nil
        } catch {
            teardown()
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    public func cancel() {
        appleTask?.cancel()
        teardown()
    }

    // MARK: - Setup

    private func check() throws {
        switch settings.engine {
        case .whisper where !settings.whisperModel.isDownloaded:
            throw VoiceError.whisperModelMissing(settings.whisperModel.title)
        case .openAI where !OpenAIKey.isSet:
            throw VoiceError.openAIKeyMissing
        default: break
        }
    }

    private static func authorizeMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw VoiceError.microphoneDenied }
        default:
            throw VoiceError.microphoneDenied
        }
    }

    private func startApple() throws {
        let recognizer = try AppleTranscriber.recognizer(language: settings.language)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        let final = ResultBox()
        appleRequest = request
        appleFinal = final
        recorder.appleRequest = request
        // Results arrive on the main queue (the recognizer's default).
        appleTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            MainActor.assumeIsolated {
                if let text = result?.bestTranscription.formattedString { self?.partial = text }
                if let result, result.isFinal {
                    final.resume(.success(result.bestTranscription.formattedString))
                } else if let error {
                    // Stopping early often ends with "no speech" though words were heard.
                    let heard = self?.partial ?? ""
                    final.resume(heard.isEmpty ? .failure(AppleTranscriber.map(error)) : .success(heard))
                }
            }
        }
    }

    private func waitForApple() async throws -> String {
        guard let appleFinal else { throw VoiceError.nothingHeard }
        // If the recognizer never sends a final result, settle for what it heard.
        let fallback = partial
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            let heard = self?.partial ?? fallback
            appleFinal.resume(heard.isEmpty ? .failure(VoiceError.nothingHeard) : .success(heard))
        }
        let text = TranscriptText.clean(try await withCheckedThrowingContinuation { appleFinal.set($0) })
        guard !text.isEmpty else { throw VoiceError.nothingHeard }
        return text
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError.unreadableAudio("there's no microphone connected.")
        }
        recorder.keepsSamples = settings.engine != .apple
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: recorder.tapBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceError.unreadableAudio("the microphone couldn't start: \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        clock?.invalidate()
        clock = nil
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0
    }

    private func teardown() {
        stopEngine()
        appleRequest = nil
        appleTask = nil
        recorder.appleRequest = nil
    }
}

/// Collects microphone buffers on the audio thread.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var _level: Float = 0
    var keepsSamples = false
    var appleRequest: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _appleRequest } }
        set { lock.withLock { _appleRequest = newValue } }
    }
    private var _appleRequest: SFSpeechAudioBufferRecognitionRequest?

    var level: Float { lock.withLock { _level } }

    func takeSamples() -> [Float] {
        lock.withLock {
            defer { samples = [] }
            return samples
        }
    }

    /// Built outside the main actor so the audio thread can call it.
    nonisolated func tapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in
            let level = AudioSamples.level(buffer)
            let converted = keepsSamples ? try? AudioSamples.convert(buffer) : nil
            lock.withLock {
                _level = level
                if let converted { samples += converted }
                _appleRequest?.append(buffer)
            }
        }
    }
}
