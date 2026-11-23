import SlateCore
import SwiftUI

/// Script › Snapshots…: saved copies of the script, compared side by side with today's.
struct SnapshotsSheet: View {
    let workspace: ScriptWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [ScriptSnapshot] = []
    @State private var selection: ScriptSnapshot.ID?
    @State private var newName = ""
    @State private var restoring: ScriptSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    List(snapshots, selection: $selection) { snapshot in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.name).lineLimit(1)
                            Text(snapshot.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(snapshot.id)
                    }
                    .overlay {
                        if snapshots.isEmpty {
                            ContentUnavailableView("No Snapshots", systemImage: "clock.arrow.circlepath",
                                                   description: Text("Save one before a big rewrite."))
                        }
                    }
                    HStack {
                        TextField("Name", text: $newName, prompt: Text("Before the rewrite"))
                            .onSubmit(save)
                        Button("Save", action: save)
                    }
                    .padding(8)
                }
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                SnapshotCompare(snapshot: snapshots.first { $0.id == selection }, current: workspace.currentActTexts)
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("Snapshots are kept in script/.snapshots/.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore…") { restoring = snapshots.first { $0.id == selection } }
                    .disabled(selection == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear(perform: reload)
        .confirmationDialog("Restore “\(restoring?.name ?? "")”?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Restore") {
                guard let snapshot = restoring else { return }
                do {
                    try workspace.restore(snapshot)
                    reload()
                } catch {
                    SlateAppModel.showError("Couldn't restore the snapshot", error)
                }
            }
        } message: {
            Text("Today's script is saved as a “Before restore” snapshot first.")
        }
    }

    private func reload() {
        snapshots = workspace.snapshots
        if selection == nil { selection = snapshots.first?.id }
    }

    private func save() {
        do {
            let snapshot = try workspace.saveSnapshot(name: newName)
            newName = ""
            reload()
            selection = snapshot.id
        } catch {
            SlateAppModel.showError("Couldn't save the snapshot", error)
        }
    }
}

/// A snapshot (left) against the script now (right), one act file at a time.
struct SnapshotCompare: View {
    let snapshot: ScriptSnapshot?
    let current: [(name: String, text: String)]
    @State private var file: String?

    var body: some View {
        if let snapshot, let old = try? snapshot.files() {
            let names = Array(Set(old.map(\.name) + current.map(\.name))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let chosen = file.flatMap { names.contains($0) ? $0 : nil } ?? names.first
            let before = old.first { $0.name == chosen }?.text ?? ""
            let after = current.first { $0.name == chosen }?.text ?? ""
            let rows = LineDiff.rows(old: lines(before), new: lines(after))
            VStack(spacing: 0) {
                HStack {
                    Picker("Act file", selection: Binding(get: { chosen ?? "" }, set: { file = $0 })) {
                        ForEach(names, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                    let changed = rows.filter { $0.kind != .same }.count
                    Text(changed == 0 ? "No changes" : "\(changed) changed \(changed == 1 ? "line" : "lines")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                HStack(spacing: 0) {
                    Text("Snapshot").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Now").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 0) {
                                cell(row.old, tint: row.kind == .removed || row.kind == .changed ? .red : nil)
                                cell(row.new, tint: row.kind == .added || row.kind == .changed ? .green : nil)
                            }
                        }
                    }
                }
                .font(.system(.callout, design: .monospaced))
            }
        } else {
            ContentUnavailableView("Choose a Snapshot", systemImage: "rectangle.split.2x1",
                                   description: Text("It's compared with the script as it is now."))
        }
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private func cell(_ text: String?, tint: Color?) -> some View {
        Text(text ?? " ")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(tint.map { $0.opacity(0.15) } ?? .clear)
            .textSelection(.enabled)
    }
}
