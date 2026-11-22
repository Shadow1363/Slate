import Foundation

/// When to remind about to-dos: the launch sheet and due-date notifications.
public enum LaunchReminderScope: String, Sendable, CaseIterable, Identifiable {
    case off, lastProject, allProjects
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .lastProject: "Last project"
        case .allProjects: "All projects"
        }
    }
}

/// A notification to schedule for a to-do's due date.
public struct DueReminder: Sendable, Equatable, Identifiable {
    /// Stable for the same to-do, so rescheduling replaces it.
    public let id: String
    public let projectName: String
    public let projectPath: String
    public let sceneID: String?
    public let title: String
    public let body: String
    /// Date and time to fire, in the user's calendar.
    public let fireDate: DateComponents
}

/// The open to-dos of one project, for the launch sheet.
public struct ProjectTodos: Sendable, Equatable, Identifiable {
    public let name: String
    public let root: URL
    public let todos: [MarginTodo]
    public var id: URL { root }

    public init(name: String, root: URL, todos: [MarginTodo]) {
        self.name = name
        self.root = root
        self.todos = todos
    }
}

public enum Reminders {
    /// Notifications for open to-dos due today or later, at `hour` on the
    /// due date (or in a minute, for one due today after that hour).
    public static func plan(projectName: String, projectRoot: URL, todos: [MarginTodo], now: Date = .now,
                            hour: Int = 9, calendar: Calendar = .current) -> [DueReminder] {
        todos.compactMap { todo in
            guard !todo.done, let due = todo.dueDate(calendar: calendar),
                  due >= calendar.startOfDay(for: now) else { return nil }
            var fire = calendar.dateComponents([.year, .month, .day], from: due)
            fire.hour = hour
            fire.minute = 0
            if let date = calendar.date(from: fire), date <= now {
                fire = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now.addingTimeInterval(60))
            }
            let words = todo.text.isEmpty ? (todo.quote.map { "“\($0)”" } ?? "To-do") : todo.text
            return DueReminder(
                id: "todo|\(projectRoot.path)|\(todo.sceneID ?? "")|\(todo.due ?? "")|\(todo.quote ?? "")|\(todo.text)",
                projectName: projectName,
                projectPath: projectRoot.path,
                sceneID: todo.sceneID,
                title: "Due today: \(projectName)",
                body: words,
                fireDate: fire
            )
        }
    }

    /// Reads a project's to-dos from disk.
    public static func todos(in projectRoot: URL) -> [MarginTodo] {
        let url = projectRoot.appending(path: MarginTodos.path)
        guard let text = try? CoordinatedFileIO.readText(url) else { return [] }
        return MarginTodos.parse(text)
    }

    /// Open to-dos per project, overdue first; projects with none are left out.
    public static func launchList(projects: [(name: String, root: URL)], today: Date = .now) -> [ProjectTodos] {
        projects.compactMap { project in
            let open = MarginTodos.sorted(todos(in: project.root).filter { !$0.done }, today: today)
            return open.isEmpty ? nil : ProjectTodos(name: project.name, root: project.root, todos: open)
        }
    }
}
