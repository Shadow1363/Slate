import SlateCore
import SwiftUI

/// Home › Pending: every open to-do in the library (margin to-dos and
/// `TODO:` comments), grouped by project. Click one to open the project
/// right at it; tick it to mark it done.
struct PendingView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, overdue, soon
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .overdue: "Overdue"
            case .soon: "Due This Week"
            }
        }
    }

    @Environment(SlateAppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.slateTheme) private var theme
    let search: String
    @State private var filter: Filter = .all

    var body: some View {
        let projects = visible
        List {
            ForEach(projects) { project in
                Section {
                    ForEach(project.todos) { item in
                        row(item, in: project)
                    }
                } header: {
                    HStack {
                        Text(project.name)
                        Text("\(project.todos.count)").foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .overlay {
            if !model.pendingLoaded {
                ProgressView()
            } else if projects.isEmpty {
                ContentUnavailableView(filter == .all ? "Nothing Pending" : "Nothing \(filter.title)", systemImage: "checkmark.circle",
                                       description: Text("Open to-dos from every project show up here: margin to-dos (⇧⌘T in the script) and TODO: comments, like /* TODO: … */ in the script or %% TODO: … %% in a note."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .onAppear { model.refreshPending() }
    }

    private var visible: [ProjectTodos] {
        let week = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        let query = search.trimmingCharacters(in: .whitespaces)
        return model.pending.compactMap { project in
            let todos = project.todos.filter { item in
                let todo = item.todo
                switch filter {
                case .all: break
                case .overdue: guard todo.isOverdue() else { return false }
                case .soon: guard let date = todo.dueDate(), date <= week else { return false }
                }
                guard !query.isEmpty else { return true }
                return [todo.text, todo.quote ?? "", item.place, project.name].contains { $0.localizedCaseInsensitiveContains(query) }
            }
            return todos.isEmpty ? nil : ProjectTodos(name: project.name, root: project.root, todos: todos)
        }
    }

    private func row(_ item: PendingTodo, in project: ProjectTodos) -> some View {
        let todo = item.todo
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                withAnimation(.snappy) { model.complete(item, in: project.root) }
            } label: {
                Image(systemName: "circle").foregroundStyle(Color(theme.margin.todo))
            }
            .buttonStyle(.plain)
            .help("Mark done")
            .accessibilityLabel("Mark done")
            VStack(alignment: .leading, spacing: 2) {
                if let quote = todo.quote { Text("“\(quote)”").italic().foregroundStyle(.secondary).lineLimit(1) }
                Text(todo.text.isEmpty ? "To-do" : todo.text)
                HStack(spacing: 6) {
                    Image(systemName: item.isComment ? "text.bubble" : "checklist")
                        .help(item.isComment ? "A TODO: comment" : "A margin to-do")
                    if !item.place.isEmpty { Text(item.place).lineLimit(1) }
                    if let due = todo.due {
                        Text(todo.isOverdue() ? "Overdue · \(DueText.format(due))" : "Due \(DueText.format(due))")
                            .foregroundStyle(todo.isOverdue() ? Color(theme.margin.overdue) : .secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward.square").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onTapGesture { open(item, in: project) }
        .help("Open \(project.name) here")
        .accessibilityAddTraits(.isButton)
    }

    private func open(_ item: PendingTodo, in project: ProjectTodos) {
        model.requestJump(to: project.root, for: item)
        model.pendingOpen = nil
        openWindow(id: SlateWindowID.project, value: project.root)
    }
}
