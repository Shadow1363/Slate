import SlateCore
import SwiftUI

/// Settings › Search: the shortcut, and every bang (area bangs can be renamed here;
/// template bangs live in each template).
struct SearchSettings: View {
    @AppStorage(SearchPreferences.shortcut) private var shortcut = SearchPreferences.defaultShortcut
    @State private var renames = SearchPreferences.renames

    var body: some View {
        let templates = NoteTemplates.load(projectTemplates: nil, globalTemplates: ProjectSession.globalTemplatesFolder)
        let bangs = Bangs.all(templates: templates, renames: renames)
        let clashes = Bangs.clashes(templates: templates, renames: renames)
        Form {
            Section {
                LabeledContent("Open Search") { ShortcutRecorder(text: $shortcut) }
                Text("Search finds notes, scenes, speeches, frames, to-dos, words and text anywhere in the project. Start with a bang to search one part; # for tags; / for all text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(bangs) { bang in
                    HStack {
                        if case .template = bang.scope {
                            Text("!" + bang.name).font(.body.monospaced()).frame(width: 90, alignment: .leading)
                        } else {
                            HStack(spacing: 0) {
                                Text("!").font(.body.monospaced())
                                TextField("bang", text: Binding(
                                    get: { renames[bang.scope.key] ?? Bangs.areas.first { $0.scope == bang.scope }?.name ?? bang.name },
                                    set: { value in
                                        let name = Bangs.normalize(value)
                                        let original = Bangs.areas.first { $0.scope == bang.scope }?.name
                                        renames[bang.scope.key] = name == original || name.isEmpty ? nil : name
                                        SearchPreferences.setRenames(renames)
                                    }
                                ))
                                .font(.body.monospaced())
                                .labelsHidden()
                            }
                            .frame(width: 90, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bang.title)
                            Text(bang.help).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if clashes.contains(bang.name) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("Another bang has this name")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Bangs")
                    Spacer()
                    Button("Reset Names") {
                        renames = [:]
                        SearchPreferences.setRenames([:])
                    }
                    .disabled(renames.isEmpty)
                }
            } footer: {
                Text("Template bangs (Characters, Locations…) are set in Universe › Edit Templates, so each project can have its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
