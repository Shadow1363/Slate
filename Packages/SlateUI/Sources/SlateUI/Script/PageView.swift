import PDFKit
import SlateCore
import SlateExport
import SwiftUI

/// Page view: the script exactly as it will print, from the Publish renderer.
/// Read-only; edits happen in Draft view, and the pages follow 300 ms later.
struct PageView: View {
    let workspace: ScriptWorkspace
    @State private var document: PDFDocument?
    @State private var renderedVersion = -1

    var body: some View {
        ZStack {
            if let document {
                PDFKitView(document: document, page: workspace.caretPageIndex)
            } else {
                ProgressView("Laying out pages…")
            }
        }
        .task(id: workspace.paginationVersion) {
            // Touch the book so pagination starts if it hasn't yet.
            _ = workspace.book
            guard workspace.paginated != nil, renderedVersion != workspace.paginationVersion else { return }
            let source = workspace.scriptSource()
            let data = await Task.detached(priority: .userInitiated) { Publisher.pdf(source) }.value
            document = PDFDocument(data: data)
            renderedVersion = workspace.paginationVersion
        }
        .accessibilityLabel("Script pages")
    }
}

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let page: Int?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        context.coordinator.lastPage = page
        if let page, let target = document.page(at: page) { view.go(to: target) }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            // Keep the reader's place across re-renders.
            let current = view.currentPage.flatMap { view.document?.index(for: $0) }
            view.document = document
            if let index = current, let target = document.page(at: min(index, document.pageCount - 1)) {
                view.go(to: target)
            }
        }
        if page != context.coordinator.lastPage {
            context.coordinator.lastPage = page
            if let page, let target = document.page(at: page) { view.go(to: target) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastPage: Int?
    }
}

/// Toolbar items for the Script area: Draft/Page, Publish menu, settings.
struct ScriptToolbar: ToolbarContent {
    @Bindable var workspace: ScriptWorkspace
    @State private var showingSettings = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $workspace.showingPages) {
                Text("Draft").tag(false)
                Text("Page").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Draft view to write; Page view shows the printed pages")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(ExportFormat.allCases.filter(\.isScript)) { format in
                    Button(format.title) { workspace.publish(format) }
                }
                Divider()
                Button("Print…") { workspace.printScript() }
            } label: {
                Label("Publish", systemImage: "square.and.arrow.up")
            }
            .help("Publish to the exports folder")
            ProductionMenu(workspace: workspace)
            Button {
                showingSettings = true
            } label: {
                Label("Publish Settings", systemImage: "slider.horizontal.3")
            }
            .help("Page size, scene numbers, (CONT'D) and emphasis")
            .popover(isPresented: $showingSettings) {
                PublishSettingsView(workspace: workspace)
            }
        }
    }
}

/// Per-project Publish options, saved in `project.json`.
struct PublishSettingsView: View {
    let workspace: ScriptWorkspace

    var body: some View {
        let settings = workspace.publishSettings
        Form {
            Picker("Page size", selection: binding(settings.pageSize) { $0.pageSize = $1 }) {
                Text("US Letter").tag(PageSize.letter)
                Text("A4").tag(PageSize.a4)
            }
            Toggle("Scene numbers", isOn: binding(settings.sceneNumbers) { $0.sceneNumbers = $1 })
            Toggle("Automatic (CONT'D)", isOn: binding(settings.autoContd) { $0.autoContd = $1 })
            Toggle("Bold, italic and underline", isOn: binding(settings.emphasis) { $0.emphasis = $1 })
            Text("Saved in project.json. The editor theme never changes Publish.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 320)
    }

    private func binding<T>(_ value: T, _ set: @escaping (inout PublishSettings, T) -> Void) -> Binding<T> {
        Binding(get: { value }, set: { newValue in workspace.updatePublishSettings { set(&$0, newValue) } })
    }
}
