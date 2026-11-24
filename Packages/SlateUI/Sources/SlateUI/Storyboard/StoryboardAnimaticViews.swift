import AppKit
import SlateCore
import SlateExport
import SwiftUI
import UniformTypeIdentifiers

/// Storyboard toolbar: Watch, Export and the board settings.
struct StoryboardToolbar: ToolbarContent {
    let session: ProjectSession
    @State private var showingSettings = false

    var body: some ToolbarContent {
        // The centre item, like Draft/Page in the script: the actions then sit on the right.
        ToolbarItem(placement: .principal) {
            Button {
                session.watch(.film)
            } label: {
                Label("Watch Animatic", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .help("Watch the animatic, whole film (⌥⌘↩)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Animatic (.mov)") { session.exportAnimatic() }
                Section("Boards PDF") {
                    ForEach(BoardsPDF.Layout.allCases) { layout in
                        Button(layout.title) { session.exportBoards(layout) }
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(session.exportJob != nil)
            .help("Export the animatic or the boards to the exports folder")
            Button {
                showingSettings = true
            } label: {
                Label("Storyboard Settings", systemImage: "slider.horizontal.3")
            }
            .help("Temp score, push-in and the sketch guide")
            .popover(isPresented: $showingSettings) {
                StoryboardSettingsView(model: session.storyboard)
            }
        }
    }
}

/// Board-wide settings, written to `storyboard/storyboard.json`.
struct StoryboardSettingsView: View {
    let model: StoryboardModel
    @State private var volume: Double?

    var body: some View {
        let settings = model.settings
        Form {
            Section("Temp Score") {
                if let score = settings.score {
                    LabeledContent("File") {
                        HStack {
                            Text(score).lineLimit(1).truncationMode(.middle)
                            Button("Replace…", action: choose)
                            Button("Remove") { model.removeScore() }
                        }
                    }
                    LabeledContent("Volume") {
                        Slider(value: Binding(get: { volume ?? settings.scoreVolume ?? 1 }, set: { volume = $0 }), in: 0...1) { editing in
                            guard !editing, let value = volume else { return }
                            model.updateSettings("Change Score Volume") { $0.scoreVolume = value >= 0.995 ? nil : value }
                            volume = nil
                        }
                        .frame(width: 160)
                    }
                } else {
                    LabeledContent("File") {
                        Button("Choose…", action: choose)
                    }
                    Text("Plays under the whole animatic. It's copied into storyboard/.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Frames") {
                Toggle("Slow push-in on stills", isOn: Binding(get: { settings.pushIn }, set: { value in
                    model.updateSettings("Change Push-In") { $0.pushIn = value }
                }))
                Text("For stills without a camera move of their own. Frames set to “push in” or “pull out” always move.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Sketch guide", selection: Binding(get: { settings.guide }, set: { guide in
                    model.updateSettings("Change Guide") { $0.guide = guide }
                })) {
                    ForEach(SketchGuide.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Also the shape frames are shown in when you watch or export.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        if let url = StoryboardAudio.choose(title: "Choose a Temp Score") { model.setScore(url) }
    }
}

/// A scene's scratch-audio marker: a speaker that opens a volume slider.
struct ScratchAudioBadge: View {
    let model: StoryboardModel
    let row: StoryboardModel.Row
    let file: String
    @State private var showing = false
    @State private var volume: Double?

    var body: some View {
        let stored = row.folder.flatMap { model.framesByFolder[$0.path]?.scratchVolume } ?? 1
        Button {
            showing = true
        } label: {
            Label("\(Int(((volume ?? stored) * 100).rounded()))%", systemImage: "speaker.wave.2.fill")
                .font(.caption.monospacedDigit())
        }
        .buttonStyle(.borderless)
        .help("Scratch audio: \(file)")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(file).font(.headline)
                Slider(value: Binding(get: { volume ?? stored }, set: { volume = $0 }), in: 0...1) {
                    Text("Volume")
                } onEditingChanged: { editing in
                    guard !editing, let value = volume else { return }
                    model.setScratchVolume(value, row: row.id)
                    volume = nil
                }
                .frame(width: 220)
                HStack {
                    Button("Replace…") {
                        if let url = StoryboardAudio.choose(title: "Choose Scratch Audio") { model.setScratchAudio(url, row: row.id) }
                    }
                    Button("Remove") {
                        showing = false
                        model.removeScratchAudio(row: row.id)
                    }
                }
            }
            .padding(14)
        }
    }
}

enum StoryboardAudio {
    /// An open panel for one sound file.
    @MainActor
    static func choose(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = StoryboardMedia.audioExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
