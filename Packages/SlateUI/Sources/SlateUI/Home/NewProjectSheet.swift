import AppKit
import SlateCore
import SwiftUI

struct NewProjectSheet: View {
    /// Called with the new project folder.
    let created: (URL) -> Void

    @Environment(SlateAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var template: ProjectTemplate = .feature
    @State private var location = SlateAppModel.defaultProjectsFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project").font(.title2.bold())
            Form {
                TextField("Title", text: $title, prompt: Text("My Film"))
                Picker("Template", selection: $template) {
                    ForEach(ProjectTemplate.allCases) { template in
                        Text(template.title).tag(template)
                    }
                }
                Text(template.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Location") {
                    HStack {
                        Text(location.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseLocation)
                    }
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = location
        if panel.runModal() == .OK, let url = panel.url {
            location = url
        }
    }

    private func create() {
        do {
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            let root = try ProjectCreator.create(title: title, template: template, in: location)
            let entry = try model.library.add(root)
            model.library.markOpened(entry.id)
            dismiss()
            created(root)
        } catch {
            SlateAppModel.showError("Couldn't create the project", error)
        }
    }
}
