import Foundation

/// A notification to schedule for a to-do's due date.
public struct DueReminder: Sendable, Equatable, Identifiable {
    /// Stable for the same to-do, so rescheduling replaces it.
    public let id: String
    public let projectName: String
    public let projectPath: String
    public let sceneID: String?
    /// For a comment to-do: its file and where the comment starts.
    public var path: String? = nil
    public var location: Int? = nil
    public let title: String
    public let body: String
    /// Date and time to fire, in the user's calendar.
    public let fireDate: DateComponents
}

/// An open to-do from anywhere in a project: a margin to-do or a `TODO:` comment.
public struct PendingTodo: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case margin(MarginTodo)
        case comment(CommentTodo)
    }

    public let kind: Kind
    /// Where it is: the scene heading, the note's name, or "" for an unanchored margin to-do.
    public let place: String

    public init(kind: Kind, place: String) {
        self.kind = kind
        self.place = place
    }

    public var id: String {
        switch kind {
        case .margin(let todo): "margin|" + todo.id
        case .comment(let todo): "comment|" + todo.id
        }
    }

    /// As a margin to-do, for its words, quote and dates.
    public var todo: MarginTodo {
        switch kind {
        case .margin(let todo): todo
        case .comment(let todo): todo.asMarginTodo
        }
    }

    public var isComment: Bool { if case .comment = kind { true } else { false } }
}

/// The open to-dos of one project, for Pending.
public struct ProjectTodos: Sendable, Equatable, Identifiable {
    public let name: String
    public let root: URL
    public let todos: [PendingTodo]
    public var id: URL { root }

    public init(name: String, root: URL, todos: [PendingTodo]) {
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
        plan(projectName: projectName, projectRoot: projectRoot, pending: todos.map { PendingTodo(kind: .margin($0), place: "") },
             now: now, hour: hour, calendar: calendar)
    }

    public static func plan(projectName: String, projectRoot: URL, pending: [PendingTodo], now: Date = .now,
                            hour: Int = 9, calendar: Calendar = .current) -> [DueReminder] {
        pending.compactMap { item in
            let todo = item.todo
            guard !todo.done, let due = todo.dueDate(calendar: calendar),
                  due >= calendar.startOfDay(for: now) else { return nil }
            var fire = calendar.dateComponents([.year, .month, .day], from: due)
            fire.hour = hour
            fire.minute = 0
            if let date = calendar.date(from: fire), date <= now {
                fire = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now.addingTimeInterval(60))
            }
            let words = todo.text.isEmpty ? (todo.quote.map { "“\($0)”" } ?? "To-do") : todo.text
            var reminder = DueReminder(
                id: "todo|\(projectRoot.path)|\(todo.sceneID ?? "")|\(todo.due ?? "")|\(todo.quote ?? "")|\(todo.text)",
                projectName: projectName,
                projectPath: projectRoot.path,
                sceneID: todo.sceneID,
                title: "Due today: \(projectName)",
                body: item.place.isEmpty ? words : "\(words) · \(item.place)",
                fireDate: fire
            )
            if case .comment(let comment) = item.kind {
                reminder.path = comment.path
                reminder.location = comment.range.location
            }
            return reminder
        }
    }

    /// Reads a project's to-dos from disk.
    public static func todos(in projectRoot: URL) -> [MarginTodo] {
        let url = projectRoot.appending(path: MarginTodos.path)
        guard let text = try? CoordinatedFileIO.readText(url) else { return [] }
        return MarginTodos.parse(text)
    }

    /// Every open to-do in a project, margin and comments, overdue first.
    public static func pending(in root: URL, today: Date = .now) -> [PendingTodo] {
        let scan = CommentTodos.scanProject(root: root)
        let margin = todos(in: root).filter { !$0.done }.map { todo in
            PendingTodo(kind: .margin(todo), place: todo.sceneID.flatMap { scan.headings[$0] } ?? "")
        }
        let comments = scan.comments.filter { !$0.done }.map { PendingTodo(kind: .comment($0), place: $0.place) }
        return sorted(margin + comments, today: today)
    }

    /// Open to-dos per project; projects with none are left out.
    public static func pending(projects: [(name: String, root: URL)], today: Date = .now) -> [ProjectTodos] {
        projects.compactMap { project in
            let open = pending(in: project.root, today: today)
            return open.isEmpty ? nil : ProjectTodos(name: project.name, root: project.root, todos: open)
        }
    }

    /// Dated first (soonest, so overdue on top), then undated in file order.
    static func sorted(_ items: [PendingTodo], today: Date) -> [PendingTodo] {
        items.enumerated().sorted { a, b in
            let da = a.element.todo.dueDate(), db = b.element.todo.dueDate()
            switch (da, db) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}
