import AppKit
import Observation
import SlateCore
import SlateVoice
import SwiftUI
import UniformTypeIdentifiers

/// Import Voice Note…: audio files transcribed into Freeform Notes.
@MainActor
@Observable
final class VoiceImportJob {
    private(set) var fileName = ""
    private(set) var index = 0
    let count: Int
    let engine: VoiceEngine
    @ObservationIgnored var task: Task<Void, Never>?

    init(count: Int, engine: VoiceEngine) {
        self.count = count
        self.engine = engine
    }

    func update(file: URL, index: Int) {
        fileName = file.lastPathComponent
        self.index = index
    }

    func cancel() { task?.cancel() }
}

extension ProjectSession {
    /// Asks for audio files and turns each into a note.
    func importVoiceNotes() {
        guard voiceImport == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Voice Notes"
        panel.message = "Each recording becomes a note with its transcript."
        panel.prompt = "Transcribe"
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importVoiceNotes(panel.urls)
    }

    func importVoiceNotes(_ urls: [URL]) {
        let settings = VoiceSettings.current()
        let job = VoiceImportJob(count: urls.count, engine: settings.engine)
        voiceImport = job
        job.task = Task {
            var lastPath: String?
            for (offset, url) in urls.enumerated() {
                job.update(file: url, index: offset + 1)
                do {
                    let text = try await Self.transcribe(url, settings: settings)
                    try Task.checkCancellation()
                    lastPath = try createVoiceNote(transcript: text, source: url)
                } catch is CancellationError {
                    break
                } catch {
                    SlateAppModel.showError("Couldn't transcribe “\(url.lastPathComponent)”", error)
                }
            }
            voiceImport = nil
            if let lastPath { open(lastPath) }
        }
    }

    static func transcribe(_ url: URL, settings: VoiceSettings) async throws -> String {
        switch settings.engine {
        case .apple: try await AppleTranscriber.transcribe(file: url, language: settings.language)
        case .whisper: try await WhisperTranscriber.shared.transcribe(file: url, model: settings.whisperModel, language: settings.isoLanguage)
        case .openAI: try await OpenAITranscriber(model: settings.openAIModel, language: settings.isoLanguage).transcribe(file: url)
        }
    }

    /// A Freeform Note named after the transcript's first words, tagged
    /// `voice-note`, with the transcript as its body. Returns its path.
    @discardableResult
    func createVoiceNote(transcript: String, source: URL) throws -> String {
        guard let template = template(for: "note") ?? templates.first else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "This project has no note templates."])
        }
        let fallback = source.deletingPathExtension().lastPathComponent
        let name = TranscriptText.title(from: transcript, fallback: fallback)
        let path = template.path(forName: name, existing: Set(allPaths))
        let existingIDs = Set(links.graph.notes.compactMap(\.noteID))
        var text = template.newNote(name: name, id: template.newID(existing: existingIDs))
        text = Frontmatter.setting("tags", to: .list([.string("voice-note")]), in: text)
        text = Frontmatter.setting("recording", to: .string(source.lastPathComponent), in: text)
        if !text.hasSuffix("\n") { text += "\n" }
        text += "\n" + transcript + "\n"
        try store.createTextFile(at: path, contents: text)
        links.refresh()
        return path
    }
}

struct VoiceImportBar: View {
    let job: VoiceImportJob

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(job.count > 1 ? "Transcribing \(job.index) of \(job.count): \(job.fileName)…" : "Transcribing \(job.fileName)…")
                .font(.callout)
                .lineLimit(1)
            Text(job.engine == .openAI ? "OpenAI" : job.engine == .whisper ? "Whisper" : "Apple")
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel") { job.cancel() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 1)
        .padding(.bottom, 14)
    }
}
