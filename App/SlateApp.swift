import SlateCore
import SlateUI
import SwiftUI

@main
struct SlateApp: App {
    @State private var model = SlateAppModel()

    var body: some Scene {
        Window("Slate", id: SlateWindowID.home) {
            HomeView()
                .environment(model)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            SlateCommands(model: model)
        }

        WindowGroup("Project", id: SlateWindowID.project, for: URL.self) { $url in
            ProjectWindow(url: url)
                .environment(model)
        }
        .defaultSize(width: 1200, height: 780)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
