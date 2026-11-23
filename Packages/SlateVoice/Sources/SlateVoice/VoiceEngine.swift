import Foundation

/// Who turns speech into text. Apple is the default: on-device, offline,
/// nothing to download.
public enum VoiceEngine: String, CaseIterable, Identifiable, Sendable {
    case apple
    case whisper
    case openAI = "openai"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apple: "Apple (on this Mac)"
        case .whisper: "Whisper (on this Mac)"
        case .openAI: "OpenAI (online)"
        }
    }

    public var summary: String {
        switch self {
        case .apple: "Recommended. Works offline with nothing to download, and shows words as you speak."
        case .whisper: "Optional download. Works offline once installed with a model; often better with names and accents. The text appears when you stop."
        case .openAI: "Sends the audio to OpenAI with your API key. Needs the internet, and OpenAI bills you per minute."
        }
    }
}

/// `UserDefaults` keys for Settings › Voice.
public enum VoicePreferences {
    public static let engine = "voice.engine"
    public static let whisperModel = "voice.whisperModel"
    public static let openAIModel = "voice.openAIModel"
    /// A BCP-47 language such as `en-US`, or empty for the system language
    /// (Apple) / automatic detection (Whisper, OpenAI).
    public static let language = "voice.language"

    public static let defaultOpenAIModel = "gpt-4o-transcribe"
    public static let openAIModels = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
}

/// The voice settings in effect, read from `UserDefaults`.
public struct VoiceSettings: Sendable, Equatable {
    public var engine: VoiceEngine
    public var whisperModel: WhisperModel
    public var openAIModel: String
    public var language: String

    public init(engine: VoiceEngine = .apple, whisperModel: WhisperModel = .defaultModel,
                openAIModel: String = VoicePreferences.defaultOpenAIModel, language: String = "") {
        self.engine = engine
        self.whisperModel = whisperModel
        self.openAIModel = openAIModel
        self.language = language
    }

    public static func current(_ defaults: UserDefaults = .standard) -> VoiceSettings {
        VoiceSettings(
            engine: defaults.string(forKey: VoicePreferences.engine).flatMap(VoiceEngine.init(rawValue:)) ?? .apple,
            whisperModel: defaults.string(forKey: VoicePreferences.whisperModel).flatMap(WhisperModel.init(rawValue:)) ?? .defaultModel,
            openAIModel: defaults.string(forKey: VoicePreferences.openAIModel).flatMap { $0.isEmpty ? nil : $0 }
                ?? VoicePreferences.defaultOpenAIModel,
            language: defaults.string(forKey: VoicePreferences.language) ?? ""
        )
    }

    /// The two-letter code Whisper and OpenAI take (`en-US` → `en`), or nil for automatic.
    public var isoLanguage: String? {
        let code = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased()
        return code?.isEmpty == false ? code : nil
    }
}

public enum VoiceError: LocalizedError, Equatable {
    case microphoneDenied
    case speechDenied
    case appleUnavailable(String)
    case whisperNotInstalled
    case whisperModelMissing(String)
    case whisperFailed(String)
    case openAIKeyMissing
    case openAIFailed(String)
    case fileTooLarge(Int)
    case unreadableAudio(String)
    case nothingHeard

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Slate isn't allowed to use the microphone. Turn it on in System Settings › Privacy & Security › Microphone."
        case .speechDenied:
            "Slate isn't allowed to use speech recognition. Turn it on in System Settings › Privacy & Security › Speech Recognition."
        case .appleUnavailable(let detail):
            "Apple's on-device speech recognition isn't available: \(detail)"
        case .whisperNotInstalled:
            "Whisper isn't installed. It's an optional download in Settings › Voice."
        case .whisperModelMissing(let name):
            "The Whisper model “\(name)” isn't downloaded yet. Download it in Settings › Voice."
        case .whisperFailed(let detail):
            "Whisper couldn't transcribe this: \(detail)"
        case .openAIKeyMissing:
            "Add your OpenAI API key in Settings › Voice first."
        case .openAIFailed(let detail):
            "OpenAI couldn't transcribe this: \(detail)"
        case .fileTooLarge(let megabytes):
            "This recording is \(megabytes) MB after converting, and OpenAI takes up to 25 MB. Use Apple or Whisper for long recordings."
        case .unreadableAudio(let detail):
            "Slate couldn't read this audio: \(detail)"
        case .nothingHeard:
            "No speech was heard."
        }
    }
}
