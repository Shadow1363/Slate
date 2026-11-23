import AppKit
import SlateCore
import SwiftUI

public enum WelcomePreferences {
    public static let showAtLaunch = "welcome.showAtLaunch"
}

/// First launch (and Help › Welcome to Slate): the sample film, a new project,
/// or an existing folder, and the four areas in a sentence each.
public struct WelcomeView: View {
    @Environment(SlateAppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(WelcomePreferences.showAtLaunch) private var showAtLaunch = true

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
                Text("Welcome to Slate").font(.largeTitle.bold())
                Text("A film's world, script, storyboard and words, as plain files in one folder.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 300)
                VStack(spacing: 8) {
                    action("Open the Sample Film", "film.stack", "Tidewater: every feature, filled in", openSample)
                    action("New Project…", "plus.square", "Feature, Short, TV Pilot or Blank") {
                        openWindow(id: SlateWindowID.home)
                        model.showingNewProject = true
                        dismissWindow(id: SlateWindowID.welcome)
                    }
                    action("Open a Folder…", "folder", "A Slate project anywhere on your Mac") {
                        if let url = model.chooseProjectFolder() {
                            openWindow(id: SlateWindowID.project, value: url)
                            dismissWindow(id: SlateWindowID.welcome)
                        }
                    }
                }
                .padding(.top, 8)
                Spacer()
                Toggle("Show this window when Slate opens", isOn: $showAtLaunch)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(28)
            .frame(width: 380)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                Text("A project has four areas").font(.headline)
                tour("globe.americas", "Universe  ⌘1", "Characters, places and rules as notes from templates; canvases, timelines with time travel, and maps.")
                tour("text.page", "Script  ⌘2", "Fountain that formats as you type, with timings, a margin for to-dos and notes, and Publish to PDF and Final Draft.")
                tour("rectangle.split.3x3", "Storyboard  ⌘3", "A row per scene, filled with images, clips and sketches, played as an animatic.")
                tour("character.book.closed", "Dictionary  ⌘4", "The film's own words and meanings, which spell check knows.")
                Text("Everything is a plain file you can open in Finder, back up or put in git.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(28)
            .frame(width: 360)
        }
        .frame(height: 470)
        .slateThemed()
    }

    private func action(_ title: String, _ icon: String, _ detail: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(width: 300)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHint(detail)
    }

    private func tour(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func openSample() {
        guard let root = model.makeSampleProject() else { return }
        openWindow(id: SlateWindowID.project, value: root)
        dismissWindow(id: SlateWindowID.welcome)
    }
}
