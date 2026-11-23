import AppKit
import Observation
import SlateCore
import SwiftUI

/// Which notes and headings are open in the Universe sidebar's index,
/// remembered per project. Keys are `<path>|` for a note and `<path>|<heading key>` for a heading.
@MainActor
@Observable
final class OutlineState {
    private(set) var open: Set<String>
    /// Notes whose state was never set: closed, except the draft, which starts open.
    private(set) var touched: Set<String>
    @ObservationIgnored let defaultsKey: String

    init(projectRoot: URL) {
        defaultsKey = "universe.outline." + projectRoot.standardizedFileURL.path
        let saved = UserDefaults.standard.dictionary(forKey: defaultsKey)
        open = Set(saved?["open"] as? [String] ?? [])
        touched = Set(saved?["touched"] as? [String] ?? [])
    }

    static func key(_ path: String, _ heading: String = "") -> String { path + "|" + heading }

    func isOpen(_ path: String, heading: String = "") -> Bool {
        let key = Self.key(path, heading)
        if !touched.contains(path) { return path == ProjectLayout.draft && heading.isEmpty }
        return open.contains(key)
    }

    func set(_ path: String, heading: String = "", open value: Bool) {
        adopt(path)
        let key = Self.key(path, heading)
        if value { open.insert(key) } else { open.remove(key) }
        save()
    }

    /// A click toggles one level; ⌥-click (`branch`) opens or closes everything below it.
    func toggle(_ path: String, heading: String = "", tree: [HeadingTree.Node], branch: Bool) {
        let value = !isOpen(path, heading: heading)
        adopt(path)
        let below: [String]
        if heading.isEmpty {
            below = HeadingTree.keys(tree)
        } else {
            below = Self.find(heading, in: tree).map { HeadingTree.keys($0.children) } ?? []
        }
        for key in [heading] + (branch ? below : []) {
            if value { open.insert(Self.key(path, key)) } else { open.remove(Self.key(path, key)) }
        }
        save()
    }

    func expandAll(_ path: String, tree: [HeadingTree.Node]) {
        adopt(path)
        for key in [""] + HeadingTree.keys(tree) { open.insert(Self.key(path, key)) }
        save()
    }

    func collapseAll(_ path: String) {
        adopt(path)
        open = open.filter { !$0.hasPrefix(path + "|") }
        save()
    }

    /// A renamed note keeps what was open.
    func move(_ old: String, to new: String) {
        guard old != new else { return }
        open = Set(open.map { $0.hasPrefix(old + "|") ? new + $0.dropFirst(old.count) : $0 })
        if touched.remove(old) != nil { touched.insert(new) }
        save()
    }

    /// The first change to a note records its default (the draft starts open).
    private func adopt(_ path: String) {
        guard !touched.contains(path) else { return }
        touched.insert(path)
        if path == ProjectLayout.draft { open.insert(Self.key(path)) }
    }

    private func save() {
        UserDefaults.standard.set(["open": Array(open).sorted(), "touched": Array(touched).sorted()], forKey: defaultsKey)
    }

    static func find(_ key: String, in nodes: [HeadingTree.Node]) -> HeadingTree.Node? {
        for node in nodes {
            if node.key == key { return node }
            if let found = find(key, in: node.children) { return found }
        }
        return nil
    }
}

/// A disclosure triangle that knows about ⌥-click.
struct OutlineChevron: View {
    let isOpen: Bool
    let toggle: (_ branch: Bool) -> Void

    var body: some View {
        Button {
            toggle(NSEvent.modifierFlags.contains(.option))
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 14, height: 14)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Show or hide headings (⌥-click for every level)")
        .accessibilityLabel(isOpen ? "Collapse" : "Expand")
    }
}

/// One heading in the index: indented by depth, with its own chevron when it has children.
struct HeadingRow: View {
    let session: ProjectSession
    let path: String
    let row: HeadingTree.Row
    let tree: [HeadingTree.Node]

    var body: some View {
        let outline = session.outline
        HStack(spacing: 4) {
            if row.node.children.isEmpty {
                Color.clear.frame(width: 14, height: 14)
            } else {
                OutlineChevron(isOpen: outline.isOpen(path, heading: row.node.key)) { branch in
                    withAnimation(.snappy(duration: 0.15)) { outline.toggle(path, heading: row.node.key, tree: tree, branch: branch) }
                }
            }
            Button {
                session.open(heading: row.node.heading, in: path)
            } label: {
                Text(row.node.heading.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(row.depth) * 12 + 18)
        .draggable("slate-heading:" + row.node.heading.title)
        .contextMenu {
            Button("Go to Heading") { session.open(heading: row.node.heading, in: path) }
            if path == ProjectLayout.draft {
                Button("Turn into Scene") {
                    session.area = .script
                    session.script.appendSceneStub(heading: row.node.heading.title)
                }
            }
            Divider()
            Button("Expand All") { outline.expandAll(path, tree: tree) }
            Button("Collapse All") { outline.collapseAll(path) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heading \(row.node.heading.title), level \(row.node.heading.level)")
    }
}

extension ProjectSession {
    /// Opens a note or the draft at one of its headings.
    func open(heading: MarkdownOutline.Heading, in path: String) {
        area = .universe
        universeSelection = path
        noteReveal = RevealRequest(file: path, location: heading.range.location, focus: true)
    }
}
