import AppKit
import SlateCore
import SwiftUI

/// Settings › Spelling.
struct SpellingSettingsView: View {
    @AppStorage(SpellingPreferences.language) private var language = ""
    @AppStorage(SpellingPreferences.grammarInScript) private var grammarInScript = false
    @AppStorage(SpellingPreferences.grammarInNotes) private var grammarInNotes = true
    @AppStorage(SpellingPreferences.autocorrect) private var autocorrect = false

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                Text("Automatic by Language").tag("")
                Divider()
                ForEach(NSSpellChecker.shared.availableLanguages, id: \.self) { code in
                    Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                }
            }
            Text("Automatic checks each paragraph in whichever of your languages it's written in (System Settings › Keyboard › Text Input).")
                .font(.caption).foregroundStyle(.secondary)
            Section("Grammar") {
                Toggle("Check grammar in the script", isOn: $grammarInScript)
                Toggle("Check grammar in notes", isOn: $grammarInNotes)
            }
            Section {
                Toggle("Correct spelling automatically", isOn: $autocorrect)
                Text("Off by default for screenwriting. Words in your dictionaries are never corrected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Every Project") {
                LabeledContent("Global words") {
                    Button("Show in Finder") {
                        let url = GlobalWords.defaultURL
                        if !FileManager.default.fileExists(atPath: url.path) {
                            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try? CoordinatedFileIO.writeText(WordBook.starter, to: url)
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
