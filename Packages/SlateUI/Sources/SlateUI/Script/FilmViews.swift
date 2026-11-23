import SlateCore
import SwiftUI

/// The film switcher above the Script and Storyboard navigators, in a saga.
struct FilmBar: View {
    let workspace: ScriptWorkspace

    var body: some View {
        let films = workspace.films
        if films.count > 1 {
            HStack(spacing: 6) {
                Picker("Film", selection: Binding(
                    get: { workspace.film.folder },
                    set: { folder in
                        if let film = films.first(where: { $0.folder == folder }) { workspace.select(film: film) }
                    }
                )) {
                    ForEach(Array(films.enumerated()), id: \.element.folder) { index, film in
                        Text("\(index + 1). \(film.title)").tag(film.folder)
                    }
                }
                .labelsHidden()
                .help("The film the Script and Storyboard show (⌃⌘[ and ⌃⌘] step through them)")
                Menu {
                    FilmMenuItems(workspace: workspace)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New, rename or remove films")
                .accessibilityLabel("Film actions")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// New Film…, Rename Film…, Move Film to Trash…
struct FilmMenuItems: View {
    let workspace: ScriptWorkspace

    var body: some View {
        Button("New Film…") { workspace.promptForNewFilm() }
        Button("Rename Film…") { workspace.promptForRename() }
            .disabled(workspace.film.isRoot)
        Divider()
        Button("Move Film to Trash…") { workspace.confirmTrashFilm() }
            .disabled(workspace.film.isRoot || workspace.films.count < 2)
    }
}
