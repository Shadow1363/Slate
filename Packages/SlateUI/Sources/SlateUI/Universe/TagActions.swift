import AppKit
import SlateCore
import SwiftUI

/// Tags on notes and scenes: setting them, and renaming or removing one everywhere.
extension ProjectSession {
    /// The project's tags, most used first (for suggestions).
    var knownTags: [String] { tagIndex.tags.map(\.tag) }

    func setTags(_ tags: [String], forNote path: String) {
        do {
            let document = try store.documents[path] ?? store.document(at: path)
            let text = Tags.settingNoteTags(tags, in: document.text)
            guard text != document.text else { return }
            document.text = text
            store.save(document)
            links.update(path: path, text: text)
        } catch {
            SlateAppModel.showError("Couldn't save the tags", error)
        }
    }

    /// Renames a tag (or removes it, with nil) on every note and every scene of every film.
    /// Returns how many files changed.
    @discardableResult
    func renameTag(_ tag: String, to new: String?) -> Int {
        let tag = Tags.normalize(tag)
        var changed = 0
        func rewrite(_ path: String, _ transform: (String) -> String) {
            do {
                let document = try store.documents[path] ?? store.document(at: path)
                let text = transform(document.text)
                guard text != document.text else { return }
                document.text = text
                store.save(document)
                if IndexedFile.isIndexed(path) { links.update(path: path, text: text) }
                changed += 1
            } catch {
                SlateAppModel.showError("Couldn't update \((path as NSString).lastPathComponent)", error)
            }
        }
        for note in links.graph.notes where Tags.noteTags(note).contains(tag) {
            rewrite(note.path) { Tags.renaming(tag, to: new, inNote: $0, path: note.path) }
        }
        for path in script.scriptPaths where Films.isActFile(path) {
            let text = store.documents[path]?.text ?? (try? store.readText(at: path)) ?? ""
            guard ScriptParser.parse(text).scenes.contains(where: { $0.tags.contains(tag) }) else { continue }
            rewrite(path) { Tags.renaming(tag, to: new, inScript: $0) }
        }
        script.refreshOtherFilms()
        spotlight?.reload()
        return changed
    }

    /// Asks for a new name, then renames everywhere.
    func promptRenameTag(_ tag: String) {
        let alert = NSAlert()
        alert.messageText = "Rename #\(tag)"
        alert.informativeText = "Every note and scene tagged #\(tag) gets the new name."
        let field = NSTextField(string: tag)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = Tags.normalize(field.stringValue)
        guard !new.isEmpty, new != tag else { return }
        renameTag(tag, to: new)
    }

    func confirmRemoveTag(_ tag: String) {
        let alert = NSAlert()
        alert.messageText = "Remove #\(tag) from everything?"
        alert.informativeText = "It comes off \(tagIndex.count(tag)) notes and scenes. The notes and scenes themselves stay."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameTag(tag, to: nil)
    }
}

extension ScriptWorkspace {
    /// Writes `tags=` into the scene's tag.
    func setTags(_ tags: [String], for scene: ScriptBook.Scene) {
        guard let document = store.documents[scene.file] else { return }
        let text = SceneEditing.settingAttribute("tags", to: Tags.attribute(tags), headingLine: scene.scene.headingLine, in: document.text)
        if text != document.text { document.text = text }
    }
}

/// The tag strip under a note's name.
struct NoteTagStrip: View {
    let session: ProjectSession
    let note: Note

    var body: some View {
        TagField(tags: Tags.noteTags(note), known: session.knownTags) { tags in
            session.setTags(tags, forNote: note.path)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

/// Script navigator › right-click a scene › Tags…
struct SceneTagsSheet: View {
    let session: ProjectSession
    let sceneID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let scene = session.script.scene(withID: sceneID)
        VStack(alignment: .leading, spacing: 14) {
            Text("Tags").font(.headline)
            if let scene {
                Text(scene.scene.heading).font(.callout.monospaced()).foregroundStyle(.secondary)
                TagField(tags: scene.scene.tags, known: session.knownTags) { tags in
                    session.script.setTags(tags, for: scene)
                }
                Text("Saved in the scene's hidden tag; they never print. Search with #tag or !t.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
