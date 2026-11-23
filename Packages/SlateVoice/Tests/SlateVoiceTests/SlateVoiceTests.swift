import Foundation
import Testing
@testable import SlateVoice

@Suite("Transcript text")
struct TranscriptTextTests {
    @Test func cleanDropsMarkersAndSpaces() {
        #expect(TranscriptText.clean(" [BLANK_AUDIO]  Hello   there. (wind blowing) ") == "Hello there.")
        #expect(TranscriptText.clean("One.\n\n  Two  ") == "One.\n\nTwo")
        #expect(TranscriptText.clean("[Music]") == "")
    }

    @Test func insertionSpacesAndCapitalizes() {
        #expect(TranscriptText.insertion("hello", preceding: "", following: nil) == "Hello")
        #expect(TranscriptText.insertion("then he left", preceding: "She waited", following: nil) == " then he left")
        #expect(TranscriptText.insertion("then he left.", preceding: "She waited. ", following: nil) == "Then he left.")
        #expect(TranscriptText.insertion("rain", preceding: "Line\n", following: nil) == "Rain")
        #expect(TranscriptText.insertion("big", preceding: "a ", following: "d") == "big ")
        #expect(TranscriptText.insertion("quote", preceding: "(", following: ")") == "quote")
    }

    @Test func titleIsTheFirstSentence() {
        #expect(TranscriptText.title(from: "Mara finds the key under the boat. Then rain.", fallback: "x")
            == "Mara finds the key under the boat")
        #expect(TranscriptText.title(from: "one two three four five six seven eight nine ten", fallback: "x")
            == "one two three four five six seven eight")
        #expect(TranscriptText.title(from: "", fallback: "Voice note") == "Voice note")
    }
}

@Suite("Audio")
struct AudioTests {
    @Test func wavHeader() {
        let data = AudioSamples.wav([0, 1, -1, 0.5])
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
    }

    @Test func wavRoundTripsThroughAVFoundation() throws {
        let tone = (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.5 }
        let url = FileManager.default.temporaryDirectory.appending(path: "slate-voice-\(UUID()).wav")
        try AudioSamples.wav(tone).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try AudioSamples.load(url)
        #expect(abs(loaded.count - tone.count) < 32)
    }
}

@Suite("Settings and OpenAI")
struct SettingsTests {
    @Test func defaultsToApple() throws {
        let defaults = try #require(UserDefaults(suiteName: "slate-voice-tests-\(UUID())"))
        let settings = VoiceSettings.current(defaults)
        #expect(settings.engine == .apple)
        #expect(settings.whisperModel == .defaultModel)
        #expect(settings.isoLanguage == nil)
        defaults.set("whisper", forKey: VoicePreferences.engine)
        defaults.set("pt-BR", forKey: VoicePreferences.language)
        #expect(VoiceSettings.current(defaults).engine == .whisper)
        #expect(VoiceSettings.current(defaults).isoLanguage == "pt")
    }

    @Test func modelURLs() {
        #expect(WhisperModel.base.downloadURL.absoluteString
            == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")
        #expect(WhisperModel.baseEnglish.isEnglishOnly)
        #expect(!WhisperModel.largeTurbo.isEnglishOnly)
    }

    @Test func multipartRequest() throws {
        let request = OpenAITranscriber(model: "gpt-4o-transcribe", language: "en")
            .request(audio: Data([1, 2, 3]), fileName: "a.wav", mimeType: "audio/wav", apiKey: "sk-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\ngpt-4o-transcribe"))
        #expect(body.contains("name=\"language\"\r\n\r\nen"))
        #expect(body.contains("filename=\"a.wav\""))
    }

    @Test func errorMessages() {
        let data = Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8)
        #expect(OpenAITranscriber.errorMessage(data, status: 401) == "Incorrect API key")
        #expect(OpenAITranscriber.errorMessage(Data(), status: 401) == "the API key was refused")
    }
}

/// Runs only with `SLATE_WHISPER_MODEL=/path/to/ggml-*.bin`: speaks a line
/// with `say` and checks whisper.cpp hears it.
@Suite("Whisper end to end")
struct WhisperEndToEndTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_WHISPER_MODEL"] != nil))
    func hearsSpokenWords() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["SLATE_WHISPER_MODEL"])
        let audio = FileManager.default.temporaryDirectory.appending(path: "slate-say-\(UUID()).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "The lighthouse keeper locked the door at midnight."]
        try say.run()
        say.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: audio) }
        let samples = try AudioSamples.load(audio)
        let text = try await WhisperTranscriber.shared.transcribe(samples, modelPath: model, language: "en")
        WhisperTranscriber.shared.unload()
        #expect(text.lowercased().contains("lighthouse"))
        #expect(text.lowercased().contains("midnight"))
    }
}
