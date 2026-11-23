import SlateCore
import SwiftUI

public struct SettingsView: View {
    @Environment(SlateAppModel.self) private var model
    @AppStorage(AppearancePreferences.appearance) private var appearance = Appearance.system.rawValue
    @AppStorage(AppearancePreferences.lightTheme) private var lightTheme = "Light"
    @AppStorage(AppearancePreferences.darkTheme) private var darkTheme = "Dark"
    @AppStorage(AppearancePreferences.textScale) private var textScale = 1.0
    @AppStorage(WelcomePreferences.showAtLaunch) private var welcomeAtLaunch = true
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        TabView {
            Form {
                Toggle("Show the welcome window when Slate opens", isOn: $welcomeAtLaunch)
                LabeledContent("Sample film") {
                    Button("Open Tidewater") { openWindow(id: SlateWindowID.welcome) }
                }
                Text("Help › Welcome to Slate shows it again at any time.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Light theme", selection: $lightTheme) {
                    ForEach(model.themes.themes) { Text($0.name).tag($0.name) }
                }
                Picker("Dark theme", selection: $darkTheme) {
                    ForEach(model.themes.themes) { Text($0.name).tag($0.name) }
                }
                if !model.themes.loadErrors.isEmpty {
                    Section("Theme problems") {
                        ForEach(model.themes.loadErrors, id: \.self) { Text($0).font(.caption) }
                    }
                }
                Picker("Text size", selection: $textScale) {
                    ForEach([0.85, 1.0, 1.15, 1.3, 1.5], id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
                }
                Text("Scales the script, notes and other editors. Publish always prints at 12 pt.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Edit Themes…") { openWindow(id: SlateWindowID.themes) }
                    Button("Reload Themes") { model.themes.reload() }
                    Button("Show Themes Folder") { showThemesFolder() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }
            SpellingSettingsView()
                .tabItem { Label("Spelling", systemImage: "textformat.abc.dottedunderline") }
            ReminderSettings()
                .tabItem { Label("Reminders", systemImage: "bell") }
            LibrarySettings()
                .tabItem { Label("Library", systemImage: "books.vertical") }
        }
        .frame(width: 520, height: 420)
        .slateThemed()
    }

    private func showThemesFolder() {
        let folder = SlateAppModel.applicationSupport.appending(path: "Themes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// Settings › Library: where Slate looks for projects.
struct LibrarySettings: View {
    @Environment(SlateAppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("New projects go in") {
                Text(SlateAppModel.defaultProjectsFolder.path(percentEncoded: false)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Watched folders") {
                ForEach(model.library.watchedFolders, id: \.self) { folder in
                    HStack {
                        Label(folder.lastPathComponent, systemImage: "folder").help(folder.path)
                        Spacer()
                        Button("Stop Watching") { model.library.removeWatchedFolder(folder) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { LibraryActions.chooseWatchedFolder(model: model) }
                Text("Slate lists every project it finds in these folders. Stopping keeps the projects in the library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
