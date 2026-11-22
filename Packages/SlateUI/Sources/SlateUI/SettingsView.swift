import SlateCore
import SwiftUI

public struct SettingsView: View {
    @Environment(SlateAppModel.self) private var model
    @AppStorage(AppearancePreferences.appearance) private var appearance = Appearance.system.rawValue
    @AppStorage(AppearancePreferences.lightTheme) private var lightTheme = "Light"
    @AppStorage(AppearancePreferences.darkTheme) private var darkTheme = "Dark"

    public init() {}

    public var body: some View {
        TabView {
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
                HStack {
                    Button("Reload Themes") { model.themes.reload() }
                    Button("Show Themes Folder") { showThemesFolder() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ReminderSettings()
                .tabItem { Label("Reminders", systemImage: "bell") }
        }
        .frame(width: 460, height: 320)
        .slateThemed()
    }

    private func showThemesFolder() {
        let folder = SlateAppModel.applicationSupport.appending(path: "Themes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
