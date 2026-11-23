import SlateCore
import SlateExport
import SwiftUI

/// The Script toolbar's Production menu: locks, revisions, reports and sides.
struct ProductionMenu: View {
    let workspace: ScriptWorkspace

    var body: some View {
        Menu {
            ProductionMenuItems(production: workspace.production) { workspace.perform($0) }
        } label: {
            Label("Production", systemImage: workspace.production.isEmpty ? "lock.open" : "lock")
        }
        .help("Lock scene numbers and pages, revisions, reports and sides")
    }
}

/// The items, shared by the toolbar menu and Script › Production.
struct ProductionMenuItems: View {
    let production: ProductionFile
    let perform: (ProductionCommand) -> Void

    var body: some View {
        Section("Locking") {
            if production.scenesLocked {
                Button("Unlock Scene Numbers…") { perform(.unlockScenes) }
            } else {
                Button("Lock Scene Numbers") { perform(.lockScenes) }
            }
            if production.pagesLocked {
                Button("Unlock Pages…") { perform(.unlockPages) }
            } else {
                Button("Lock Pages") { perform(.lockPages) }
            }
        }
        Section(production.currentRevision.map { "Revisions · now \($0.color.rawValue)" } ?? "Revisions") {
            Button("Start \(production.nextColor.rawValue) Revision") { perform(.startRevision) }
            if !production.revisions.isEmpty {
                Button("Clear Revisions…") { perform(.clearRevisions) }
            }
        }
        Section("Reports") {
            ForEach(ProductionReport.allCases) { report in
                Menu(report.title) {
                    Button("PDF") { perform(.report(report, csv: false)) }
                    Button("CSV (spreadsheet)") { perform(.report(report, csv: true)) }
                }
            }
            Button("Sides…") { perform(.sides) }
        }
    }
}

/// Pick scenes for a shoot day's sides.
struct SidesSheet: View {
    let workspace: ScriptWorkspace
    @State private var chosen: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let scenes = workspace.book.scenes.filter { $0.scene.sceneID != nil }
        let labels = workspace.sceneLabels
        VStack(alignment: .leading, spacing: 12) {
            Text("Sides").font(.title2.bold())
            Text("The script pages for these scenes, with everything else on them crossed out.")
                .foregroundStyle(.secondary)
            List(scenes) { scene in
                let id = scene.scene.sceneID!
                Toggle(isOn: Binding(get: { chosen.contains(id) }, set: { on in
                    if on { chosen.insert(id) } else { chosen.remove(id) }
                })) {
                    HStack {
                        Text(labels[safe: scene.number - 1] ?? "\(scene.number)").monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 30, alignment: .trailing)
                        Text(scene.scene.heading).lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Button("Current Scene") {
                    if let id = workspace.currentScene?.scene.sceneID { chosen.insert(id) }
                }
                .disabled(workspace.currentScene?.scene.sceneID == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export Sides") {
                    do {
                        let url = try workspace.writeSides(sceneIDs: chosen)
                        dismiss()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch {
                        SlateAppModel.showError("Couldn't export the sides", error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

extension Array {
    /// The element at `index`, or nil when it's out of range.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
