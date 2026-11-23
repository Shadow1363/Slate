import SlateCore
import SwiftUI

/// The right-hand panel: the selected event, lane or branch.
struct TimelineInspector: View {
    let context: TimelineContext

    var body: some View {
        let model = context.model
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let id = model.selectedEvent, let event = context.timeline.event(id) {
                    EventInspector(context: context, event: event).id(id)
                } else if let id = model.selectedLane, let lane = context.timeline.lane(id) {
                    LaneInspector(context: context, lane: lane).id(id)
                } else if let id = model.selectedBranch {
                    BranchInspector(context: context, branchID: id).id(id)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }
}

/// A text field that saves when you press Return or leave it, so typing is one undo step.
struct CommitField: View {
    let title: String
    let value: String
    var placeholder = ""
    var multiline = false
    let commit: (String) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: Binding(get: { draft ?? value }, set: { draft = $0 }), axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder)
                .lineLimit(multiline ? 2...8 : 1...1)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
                .onDisappear(perform: save)
        }
    }

    private func save() {
        guard let draft else { return }
        self.draft = nil
        if draft != value { commit(draft) }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }
}

// MARK: - Event

private struct EventInspector: View {
    let context: TimelineContext
    let event: TimelineEvent

    private var model: TimelineModel { context.model }
    private var file: TimelineFile { context.timeline }

    private func change(_ action: String, _ body: @escaping (inout TimelineEvent) -> Void) {
        model.edit(action) { TimelineEditing.updating(event.id, in: $0, body) }
    }

    var body: some View {
        let scale = file.scale
        Label("Event", systemImage: "smallcircle.filled.circle").font(.headline)
        CommitField(title: "Title", value: event.title) { value in change("Rename Event") { $0.title = value } }
        CommitField(title: "When", value: event.world, placeholder: scale.example) { value in change("Change Time") { $0.world = value } }
        if context.analysis.start(event.id) != nil {
            Text(scale.label(event.world)).font(.caption).foregroundStyle(.secondary)
        }
        CommitField(title: "Ends (for a span)", value: event.end ?? "", placeholder: "Leave empty for a moment") { value in
            change("Change End") { $0.end = value }
        }

        Picker("Lane", selection: Binding(get: { event.lane ?? "" }, set: { lane in change("Change Lane") { $0.lane = lane } })) {
            Text("No lane").tag("")
            ForEach(file.lanes) { Text($0.name).tag($0.id) }
        }
        if !file.branches.isEmpty {
            Picker("Branch", selection: Binding(get: { file.branch(of: event) }, set: { branch in
                change("Change Branch") { $0.branch = branch == file.mainBranch ? nil : branch }
            })) {
                ForEach(file.branches) { Text($0.id == file.mainBranch ? "Main" : $0.name).tag($0.id) }
            }
        }

        LocationField(context: context, event: event)

        InspectorSection("Scenes") {
            if context.scenes.isEmpty {
                Text("The script has no scenes yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(event.scenes.filter { id in !context.scenes.contains { $0.id == id } }, id: \.self) { missing in
                Label("\(missing) isn't in the script", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            ForEach(context.scenes, id: \.id) { scene in
                Toggle(isOn: Binding(get: { event.scenes.contains(scene.id) }, set: { on in
                    change(on ? "Link Scene" : "Unlink Scene") { e in
                        e.scenes = on ? e.scenes + [scene.id] : e.scenes.filter { $0 != scene.id }
                    }
                })) {
                    Text(scene.heading).lineLimit(1).font(.callout)
                }
                .toggleStyle(.checkbox)
            }
        }

        InspectorSection("Happens after") {
            let others = context.analysis.worldOrder.filter { $0.id != event.id }
            ForEach(event.after, id: \.self) { cause in
                HStack {
                    Text(file.event(cause)?.title ?? cause).lineLimit(1)
                    Spacer()
                    Button { change("Remove Cause") { $0.after.removeAll { $0 == cause } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Menu("Add Cause") {
                ForEach(others.filter { !event.after.contains($0.id) }) { other in
                    Button(other.title + " · " + file.scale.label(other.world)) { change("Add Cause") { $0.after.append(other.id) } }
                }
            }
            .fixedSize()
            .help("Events that must come before this one on everyone's line")
        }

        let jumps = file.jumps.enumerated().filter { $0.element.from == event.id || $0.element.to == event.id }
        InspectorSection("Jumps") {
            ForEach(jumps, id: \.offset) { index, jump in
                HStack {
                    let leaving = jump.from == event.id
                    Image(systemName: leaving ? "arrow.up.forward" : "arrow.down.forward")
                    Text((context.timeline.lane(jump.traveller)?.name ?? jump.traveller) + (leaving ? " leaves for " : " arrives from ")
                         + (file.event(leaving ? jump.to : jump.from)?.title ?? "?"))
                        .lineLimit(2).font(.callout)
                    Spacer()
                    Button {
                        model.edit("Delete Jump") { TimelineEditing.removingJump(at: index, from: $0) }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Jump From Here…") { model.pendingJump = event.id }
        }

        CommitField(title: "Summary", value: event.summary ?? "", multiline: true) { value in change("Edit Summary") { $0.summary = value } }
        ColorMenu(selected: event.color) { color in change("Change Colour") { $0.color = color } }

        let warnings = context.warnings(for: event.id)
        if !warnings.isEmpty {
            InspectorSection("Continuity") {
                ForEach(warnings) { Label($0.message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            }
        }
        Divider()
        HStack {
            Button("Branch From Here") { model.branch(from: event.id) }
            Spacer()
            Button("Delete", role: .destructive) { model.deleteSelection() }
        }
    }
}

/// Where an event happens: a location note, or any name.
private struct LocationField: View {
    let context: TimelineContext
    let event: TimelineEvent

    var body: some View {
        let graph = context.session.links.graph
        let resolved = event.location.flatMap { graph.resolve($0)?.path }.flatMap(graph.note(at:))
        let locations = graph.notes.filter { $0.type?.lowercased() == "location" }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                CommitField(title: "Where", value: resolved?.name ?? event.location ?? "", placeholder: "A location note or any place") { value in
                    // Store a note's id when it has one, so renames never break the link.
                    let note = graph.note(named: value)
                    context.model.edit("Change Location") {
                        TimelineEditing.updating(event.id, in: $0) { $0.location = note.map { $0.noteID ?? $0.path } ?? value }
                    }
                }
                Menu {
                    ForEach(locations) { note in
                        Button(note.name) {
                            context.model.edit("Change Location") {
                                TimelineEditing.updating(event.id, in: $0) { $0.location = note.noteID ?? note.path }
                            }
                        }
                    }
                } label: { Image(systemName: "mappin.and.ellipse") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.top, 14)
                    .disabled(locations.isEmpty)
                    .help("Choose a location note")
            }
            if let resolved {
                Button("Open \(resolved.name)") { context.session.open(resolved.path) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

// MARK: - Lane

private struct LaneInspector: View {
    let context: TimelineContext
    let lane: TimelineLane

    var body: some View {
        let model = context.model
        let graph = context.session.links.graph
        let note = lane.note.flatMap { graph.resolve($0)?.path }.flatMap(graph.note(at:))
        Label("Lane", systemImage: "line.3.horizontal").font(.headline)
        CommitField(title: "Name", value: lane.name) { value in
            model.edit("Rename Lane") { TimelineEditing.updatingLane(lane.id, in: $0) { $0.name = value } }
        }
        VStack(alignment: .leading, spacing: 3) {
            Text("Note").font(.caption).foregroundStyle(.secondary)
            Menu(note?.name ?? lane.note ?? "None") {
                Button("None") { model.edit("Unlink Note") { TimelineEditing.updatingLane(lane.id, in: $0) { $0.note = nil } } }
                Divider()
                ForEach(graph.notes) { candidate in
                    Button(candidate.name) {
                        model.edit("Link Note") { TimelineEditing.updatingLane(lane.id, in: $0) { $0.note = candidate.noteID ?? candidate.path } }
                    }
                }
            }
            if let note {
                Button("Open \(note.name)") { context.session.open(note.path) }.buttonStyle(.link).font(.caption)
            }
        }
        ColorMenu(selected: lane.color) { color in
            model.edit("Change Colour") { TimelineEditing.updatingLane(lane.id, in: $0) { $0.color = color } }
        }
        let count = context.timeline.events.filter { $0.lane == lane.id }.count
        Text("\(count) events · \(context.analysis.jumps(of: lane.id).count) jumps").font(.caption).foregroundStyle(.secondary)
        Button("Follow \(lane.name)'s Life") {
            model.traveller = lane.id
            model.mode = .personal
        }
        Divider()
        Button("Delete Lane", role: .destructive) { model.deleteSelection() }
            .help("Its events stay, with no lane")
    }
}

// MARK: - Branch

private struct BranchInspector: View {
    let context: TimelineContext
    let branchID: String

    var body: some View {
        let model = context.model
        let file = context.timeline
        let branch = file.branchNamed(branchID)
        let events = context.analysis.worldOrder
        Label("Branch", systemImage: "arrow.triangle.branch").font(.headline)
        if let branch {
            CommitField(title: "Name", value: branch.name) { value in
                model.edit("Rename Branch") { TimelineEditing.updatingBranch(branchID, in: $0) { $0.name = value } }
            }
            Picker("Forks from", selection: Binding(get: { branch.forksFrom ?? "" }, set: { id in
                model.edit("Change Fork") { TimelineEditing.updatingBranch(branchID, in: $0) { $0.forksFrom = id } }
            })) {
                Text("Nothing").tag("")
                ForEach(events) { Text($0.title).tag($0.id) }
            }
            Picker("Rejoins at", selection: Binding(get: { branch.rejoins ?? "" }, set: { id in
                model.edit("Change Rejoin") { TimelineEditing.updatingBranch(branchID, in: $0) { $0.rejoins = id } }
            })) {
                Text("Never").tag("")
                ForEach(events) { Text($0.title).tag($0.id) }
            }
            ColorMenu(selected: branch.color) { color in
                model.edit("Change Colour") { TimelineEditing.updatingBranch(branchID, in: $0) { $0.color = color } }
            }
            Divider()
            Button("Delete Branch", role: .destructive) { model.deleteSelection() }
                .help("Its events move to the main line")
        } else {
            Text("Events here use the branch “\(branchID)”, which isn't listed in the file.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
