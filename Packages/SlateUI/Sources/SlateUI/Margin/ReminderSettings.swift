import SlateCore
import SwiftUI

/// Settings › Reminders.
struct ReminderSettings: View {
    @Environment(SlateAppModel.self) private var model
    @AppStorage(ReminderPreferences.notifications) private var notifications = true

    var body: some View {
        Form {
            Toggle("Notify me when a to-do is due", isOn: $notifications)
            Text("Notifications arrive at 9:00 on the due date, for margin to-dos and TODO: comments. macOS asks for permission the first time a to-do has a due date. Every open to-do is listed in the library under Pending.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: notifications) { model.rescheduleAll() }
    }
}
