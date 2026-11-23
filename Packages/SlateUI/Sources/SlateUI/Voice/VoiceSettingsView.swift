import SlateVoice
import SwiftUI

/// Settings › Voice: who transcribes dictation and voice notes.
struct VoiceSettingsView: View {
    @AppStorage(VoicePreferences.engine) private var engine = VoiceEngine.apple.rawValue
    @AppStorage(VoicePreferences.whisperModel) private var whisperModel = WhisperModel.defaultModel.rawValue
    @AppStorage(VoicePreferences.openAIModel) private var openAIModel = VoicePreferences.defaultOpenAIModel
    @AppStorage(VoicePreferences.language) private var language = ""
    @State private var downloads = WhisperModelDownloads()
    @State private var apiKey = ""
    @State private var keySaved = OpenAIKey.isSet

    private static let languages: [(String, String)] = [
        ("", "Automatic (system language)"), ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"),
        ("pt-BR", "Portuguese (Brazil)"), ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"), ("ja-JP", "Japanese"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Transcribe with", selection: $engine) {
                    ForEach(VoiceEngine.allCases) { option in
                        Text(option == .apple ? option.title + " — Recommended" : option.title).tag(option.rawValue)
                    }
                }
                Text((VoiceEngine(rawValue: engine) ?? .apple).summary)
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: $language) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
            } footer: {
                Text("Edit › Dictate (⇧⌘D) types what you say at the cursor. File › Import Voice Note… turns recordings into notes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if engine == VoiceEngine.whisper.rawValue {
                Section {
                    let _ = downloads.revision
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Whisper engine")
                            Text(WhisperEngine.isInstalled ? "Installed" : "Not installed · \(WhisperEngine.sizeDescription)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if downloads.downloading == .engine {
                            ProgressView(value: downloads.progress).frame(width: 90)
                            Button("Cancel") { downloads.cancel() }.controlSize(.small)
                        } else if WhisperEngine.isInstalled {
                            Button("Remove") { downloads.uninstallEngine() }.controlSize(.small)
                        } else {
                            Button("Download") { downloads.download(.engine) }
                                .controlSize(.small)
                                .disabled(downloads.downloading != nil)
                        }
                    }
                } header: {
                    Text("Whisper (optional)")
                } footer: {
                    Text("Whisper isn't part of Slate. Download it only if you want it; Slate checks the file before installing it. You also need a model below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Whisper model") {
                    let _ = downloads.revision
                    ForEach(WhisperModel.allCases) { model in
                        HStack {
                            Button {
                                whisperModel = model.rawValue
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: whisperModel == model.rawValue ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(whisperModel == model.rawValue ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading) {
                                        Text(model.title)
                                        Text(model.sizeDescription).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(whisperModel == model.rawValue ? .isSelected : [])
                            Spacer()
                            modelStatus(model)
                        }
                    }
                    if let error = downloads.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Text("Models are saved in ~/Library/Application Support/Slate/Whisper.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if engine == VoiceEngine.openAI.rawValue {
                Section("OpenAI") {
                    Picker("Model", selection: $openAIModel) {
                        ForEach(VoicePreferences.openAIModels, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        SecureField("API key", text: $apiKey, prompt: Text(keySaved ? "Saved in your keychain" : "sk-…"))
                        Button("Save") {
                            keySaved = OpenAIKey.save(apiKey) && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                            apiKey = ""
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        if keySaved {
                            Button("Remove") {
                                OpenAIKey.save("")
                                keySaved = false
                            }
                        }
                    }
                    Text("The key stays in your login keychain. Audio goes to OpenAI only when you dictate or import with this option.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func modelStatus(_ model: WhisperModel) -> some View {
        if downloads.downloading == .model(model) {
            ProgressView(value: downloads.progress).frame(width: 90)
            Button("Cancel") { downloads.cancel() }.controlSize(.small)
        } else if model.isDownloaded {
            Text("Downloaded").font(.caption).foregroundStyle(.secondary)
            Button("Delete") { downloads.delete(model) }.controlSize(.small)
        } else {
            Button("Download") {
                whisperModel = model.rawValue
                downloads.download(.model(model))
            }
            .controlSize(.small)
            .disabled(downloads.downloading != nil)
        }
    }
}
