import AppKit
import SlateCore
import SwiftUI

/// Settings › Spelling.
struct SpellingSettingsView: View {
    @AppStorage(SpellingPreferences.language) private var language = ""
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
            Section("Where to check") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        Text("Spelling").font(.caption).foregroundStyle(.secondary)
                        Text("Grammar").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(EditorSpelling.Area.allCases) { area in
                        GridRow {
                            Text(area.title)
                            AreaToggle(key: SpellingPreferences.checkKey(area), fallback: SpellingPreferences.defaultCheck(area),
                                       label: "Check spelling in \(area.title)")
                            AreaToggle(key: SpellingPreferences.grammarKey(area), fallback: SpellingPreferences.defaultGrammar(area),
                                       label: "Check grammar in \(area.title)")
                        }
                    }
                }
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

/// One checkbox bound to a UserDefaults key with a default.
private struct AreaToggle: View {
    let key: String
    let fallback: Bool
    let label: String
    @State private var on = false

    var body: some View {
        Toggle(label, isOn: Binding(get: { on }, set: { value in
            on = value
            UserDefaults.standard.set(value, forKey: key)
        }))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .onAppear { on = UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }
    }
}
