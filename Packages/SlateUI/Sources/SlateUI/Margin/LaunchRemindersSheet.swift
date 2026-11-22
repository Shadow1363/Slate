import SlateCore
import SwiftUI

/// Shown once at launch: open to-dos, overdue first, for the last project
/// (or every project, per Settings › Reminders).
struct LaunchRemindersSheet: View {
    @Environment(SlateAppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.slateTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open To-dos").font(.title2.weight(.semibold))
                Text(summary).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            List {
                ForEach(model.launchReminders) { project in
                    Section(project.name) {
                        ForEach(project.todos) { todo in
                            row(todo, in: project)
                        }
                    }
                }
            }
            .overlay {
                if model.launchReminders.isEmpty {
                    ContentUnavailableView("All Done", systemImage: "checkmark.circle", description: Text("No open to-dos left."))
                }
            }
            Divider()
            HStack {
                SettingsLink { Text("Reminder Settings…") }
                    .buttonStyle(.link)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 460)
    }

    private var summary: String {
        let all = model.launchReminders.flatMap(\.todos)
        let overdue = all.filter { $0.isOverdue() }.count
        let count = "\(all.count) open \(all.count == 1 ? "to-do" : "to-dos")"
        return overdue > 0 ? "\(count), \(overdue) overdue." : count + "."
    }

    private func row(_ todo: MarginTodo, in project: ProjectTodos) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "circle").foregroundStyle(Color(theme.margin.todo))
            VStack(alignment: .leading, spacing: 2) {
                if let quote = todo.quote { Text("“\(quote)”").italic().foregroundStyle(.secondary).lineLimit(1) }
                Text(todo.text.isEmpty ? "To-do" : todo.text)
                if let due = todo.due {
                    Text(todo.isOverdue() ? "Overdue · \(DueText.format(due))" : "Due \(DueText.format(due))")
                        .font(.caption)
                        .foregroundStyle(todo.isOverdue() ? Color(theme.margin.overdue) : .secondary)
                }
            }
            Spacer()
            if todo.sceneID != nil {
                Button("Go to Scene") {
                    model.requestJump(to: project.root, sceneID: todo.sceneID, quote: todo.quote)
                    model.pendingOpen = nil
                    openWindow(id: SlateWindowID.project, value: project.root)
                    dismiss()
                }
            }
            Button("Done") { model.complete(todo, in: project.root) }
        }
        .padding(.vertical, 2)
    }
}

/// Settings › Reminders.
struct ReminderSettings: View {
    @Environment(SlateAppModel.self) private var model
    @AppStorage(ReminderPreferences.launchScope) private var scope = LaunchReminderScope.lastProject.rawValue
    @AppStorage(ReminderPreferences.notifications) private var notifications = true

    var body: some View {
        Form {
            Picker("Show open to-dos at launch", selection: $scope) {
                ForEach(LaunchReminderScope.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Notify me when a to-do is due", isOn: $notifications)
            Text("Notifications arrive at 9:00 on the due date. macOS asks for permission the first time a to-do has a due date.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: notifications) { model.rescheduleAll() }
    }
}
