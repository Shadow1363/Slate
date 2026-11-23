@preconcurrency import AVFoundation
import Foundation
import Security

/// The OpenAI API key, kept in the login keychain.
public enum OpenAIKey {
    private static let service = "app.slate.openai"
    private static let account = "api-key"

    public static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Saves the key, or removes it when empty.
    @discardableResult
    public static func save(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrLabel as String] = "Slate – OpenAI API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static var isSet: Bool { read() != nil }
}

/// `POST /v1/audio/transcriptions`.
public struct OpenAITranscriber: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let maxBytes = 25 * 1024 * 1024
    /// What the endpoint accepts as-is; anything else is converted to WAV first.
    static let acceptedExtensions: Set<String> = ["flac", "m4a", "mp3", "mp4", "mpeg", "mpga", "oga", "ogg", "wav", "webm"]

    public var model: String
    public var language: String?

    public init(model: String, language: String?) {
        self.model = model
        self.language = language
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { throw VoiceError.nothingHeard }
        return try await upload(AudioSamples.wav(samples), fileName: "dictation.wav", mimeType: "audio/wav")
    }

    public func transcribe(file: URL) async throws -> String {
        let ext = file.pathExtension.lowercased()
        if Self.acceptedExtensions.contains(ext) {
            let data = try Data(contentsOf: file)
            if data.count <= Self.maxBytes {
                return try await upload(data, fileName: "voice-note.\(ext)", mimeType: Self.mimeType(ext))
            }
        }
        // Converted to 16 kHz mono WAV: about 32 KB a second, so ~13 minutes fits.
        let samples = try await Task.detached(priority: .userInitiated) { try AudioSamples.load(file) }.value
        let wav = AudioSamples.wav(samples)
        guard wav.count <= Self.maxBytes else { throw VoiceError.fileTooLarge(wav.count / 1_048_576) }
        return try await upload(wav, fileName: "voice-note.wav", mimeType: "audio/wav")
    }

    static func mimeType(_ ext: String) -> String {
        switch ext {
        case "m4a", "mp4": "audio/mp4"
        case "mp3", "mpeg", "mpga": "audio/mpeg"
        case "wav": "audio/wav"
        case "webm": "audio/webm"
        case "flac": "audio/flac"
        case "ogg", "oga": "audio/ogg"
        default: "application/octet-stream"
        }
    }

    /// The multipart body for a request, split out for tests.
    func request(audio: Data, fileName: String, mimeType: String, apiKey: String) -> URLRequest {
        let boundary = "slate-\(UUID().uuidString)"
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        if let language { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    private func upload(_ audio: Data, fileName: String, mimeType: String) async throws -> String {
        guard let apiKey = OpenAIKey.read() else { throw VoiceError.openAIKeyMissing }
        let request = request(audio: audio, fileName: fileName, mimeType: mimeType, apiKey: apiKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VoiceError.openAIFailed(Self.errorMessage(data, status: status)) }
        struct Reply: Decodable { let text: String }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw VoiceError.openAIFailed("an unexpected reply")
        }
        let text = TranscriptText.clean(reply.text)
        guard !text.isEmpty else { throw VoiceError.nothingHeard }
        return text
    }

    static func errorMessage(_ data: Data, status: Int) -> String {
        struct Failure: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            return failure.error.message
        }
        return status == 401 ? "the API key was refused" : "HTTP \(status)"
    }
}
