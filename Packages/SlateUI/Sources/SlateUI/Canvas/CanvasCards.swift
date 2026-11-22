import AppKit
import SlateCore
import SwiftUI

/// JSON Canvas preset colours ("1"–"6"), or a hex colour.
enum CanvasColor {
    static let presets: [(id: String, name: String, color: Color)] = [
        ("1", "Red", Color(red: 0.91, green: 0.30, blue: 0.27)),
        ("2", "Orange", Color(red: 0.95, green: 0.55, blue: 0.20)),
        ("3", "Yellow", Color(red: 0.93, green: 0.78, blue: 0.20)),
        ("4", "Green", Color(red: 0.30, green: 0.70, blue: 0.40)),
        ("5", "Cyan", Color(red: 0.20, green: 0.65, blue: 0.80)),
        ("6", "Purple", Color(red: 0.60, green: 0.40, blue: 0.85)),
    ]

    static func color(_ value: String?) -> Color? {
        guard let value, !value.isEmpty else { return nil }
        if let preset = presets.first(where: { $0.id == value }) { return preset.color }
        var hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255, blue: Double(number & 0xFF) / 255)
    }
}

/// One card's contents at world size (the board scales it).
struct CanvasCardView: View {
    let session: ProjectSession
    let model: CanvasModel
    let node: CanvasNode
    @Environment(\.slateTheme) private var theme

    var body: some View {
        let tint = CanvasColor.color(node.color)
        Group {
            switch node.card {
            case .text:
                TextCard(model: model, node: node)
            case .note(let path):
                NoteCard(session: session, path: path)
            case .scene(let file, let sceneID):
                SceneCard(session: session, file: file, sceneID: sceneID)
            case .image(let path):
                ImageCard(session: session, path: path)
            case .link(let url):
                LinkCard(url: url)
            case .file(let path):
                Label((path as NSString).lastPathComponent, systemImage: "doc")
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .unknown(let type):
                Label("“\(type)” card (from another app)", systemImage: "questionmark.square.dashed")
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .group:
                EmptyView()
            }
        }
        .frame(width: node.rect.width, height: node.rect.height, alignment: .topLeading)
        .background(fill(tint), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint ?? Color(theme.canvas.connector).opacity(0.35), lineWidth: tint == nil ? 1 : 2))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func fill(_ tint: Color?) -> Color {
        if let tint { return tint.opacity(0.12).mix(with: Color(theme.canvas.textCard), by: 0.5) }
        switch node.card {
        case .note: return Color(theme.canvas.noteCard)
        case .scene: return Color(theme.canvas.sceneCard)
        case .image: return Color(theme.canvas.imageCard)
        default: return Color(theme.canvas.textCard)
        }
    }
}

/// A group's frame: a tinted area with its label above the top-left corner.
struct CanvasGroupView: View {
    let node: CanvasNode
    let scale: Double
    @Environment(\.slateTheme) private var theme

    var body: some View {
        let tint = CanvasColor.color(node.color)
        RoundedRectangle(cornerRadius: 12)
            .fill(tint?.opacity(0.10) ?? Color(theme.canvas.groupFill))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((tint ?? Color(theme.canvas.connector)).opacity(0.5), lineWidth: 1.5))
            .overlay(alignment: .topLeading) {
                if let label = node.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 13 / max(scale, 0.35) * min(scale, 1), weight: .semibold))
                        .foregroundStyle(tint ?? .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.background.opacity(0.8), in: .rect(cornerRadius: 4))
                        .offset(x: 6, y: -24)
                        .fixedSize()
                }
            }
    }
}

/// Rendered Markdown; double-click edits the raw text.
private struct TextCard: View {
    let model: CanvasModel
    let node: CanvasNode
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if model.editingText == node.id {
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(8)
                .onAppear {
                    draft = node.text
                    focused = true
                }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onKeyPress(.escape) {
                    commit()
                    return .handled
                }
                .onDisappear { commit() }
        } else {
            ScrollView {
                MarkdownBlocks(text: node.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollDisabled(true)
            .overlay {
                if node.text.isEmpty {
                    Text("Double-click to write").foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func commit() {
        guard model.editingText == node.id else { return }
        model.editingText = nil
        if draft != node.text {
            let id = node.id
            let text = draft
            model.edit("Edit Text") { CanvasEditing.updating(id, in: $0) { $0.text = text } }
        }
    }
}

/// Markdown blocks: headings, bullets, quotes and paragraphs, with inline
/// emphasis, `[[links]]` and spoilers.
struct MarkdownBlocks: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let line):
                    SpoilerText(text: line)
                        .font(.system(size: level == 1 ? 22 : level == 2 ? 18 : 15, weight: .bold))
                case .bullet(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        SpoilerText(text: line)
                    }
                case .task(let done, let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done ? "checkmark.square" : "square")
                        SpoilerText(text: line).strikethrough(done)
                    }
                case .quote(let line):
                    SpoilerText(text: line)
                        .italic()
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2) }
                case .paragraph(let line):
                    SpoilerText(text: line)
                case .rule:
                    Divider()
                }
            }
        }
        .font(.system(size: 14))
    }

    enum Block {
        case heading(Int, String), bullet(String), task(Bool, String), quote(String), paragraph(String), rule
    }

    var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let match = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush(); result.append(.heading(match.1.count, String(match.2)))
            } else if let match = line.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.*)$/) {
                flush(); result.append(.task(match.1 != " ", String(match.2)))
            } else if let match = line.firstMatch(of: /^(?:[-*+]|\d+[.)])\s+(.*)$/) {
                flush(); result.append(.bullet(String(match.1)))
            } else if let match = line.firstMatch(of: /^>\s?(.*)$/) {
                flush(); result.append(.quote(String(match.1)))
            } else if line.allSatisfy({ $0 == "-" || $0 == "*" }), line.count >= 3 {
                flush(); result.append(.rule)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }
}

/// A live view of a note: its infobox and the start of its body.
private struct NoteCard: View {
    let session: ProjectSession
    let path: String

    var body: some View {
        if let note = session.links.graph.note(at: path) {
            let template = session.template(for: note.type)
            let text = (try? session.store.readText(at: path)) ?? ""
            let bodyText = Frontmatter.split(text).body.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: template?.icon ?? icon(for: note.type)).foregroundStyle(.secondary)
                    Text(note.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(template?.label ?? "Note").font(.caption).foregroundStyle(.secondary)
                }
                InfoboxRows(content: InfoboxContent.make(note: note, template: template, store: session.store).limited(to: 5), compact: true)
                if !bodyText.isEmpty {
                    Divider()
                    MarkdownBlocks(text: String(bodyText.prefix(500)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Label("Missing note: \((path as NSString).lastPathComponent)", systemImage: "questionmark.folder")
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A scene from the script: number, heading and length.
private struct SceneCard: View {
    let session: ProjectSession
    let file: String
    let sceneID: String

    var body: some View {
        let scene = session.script.book.scenes.first { $0.scene.sceneID == sceneID }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "film").foregroundStyle(.secondary)
                Text(scene.map { "Scene \($0.number)" } ?? "Scene").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let scene { Text(eighths(scene.eighths)).font(.caption).foregroundStyle(.secondary) }
            }
            Text(scene?.scene.heading ?? "Scene \(sceneID) isn't in the script any more")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(scene == nil ? .secondary : .primary)
            Spacer(minLength: 0)
            Text((file as NSString).lastPathComponent).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func eighths(_ value: Int) -> String {
        let pages = value / 8, rest = value % 8
        return pages == 0 ? "\(rest)/8" : rest == 0 ? "\(pages) pg" : "\(pages) \(rest)/8"
    }
}

private struct ImageCard: View {
    let session: ProjectSession
    let path: String

    var body: some View {
        if let url = try? session.store.url(for: path), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .accessibilityLabel((path as NSString).lastPathComponent)
        } else {
            Label("Missing image: \((path as NSString).lastPathComponent)", systemImage: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A web link (no web view: Slate shows the address; double-click opens it).
private struct LinkCard: View {
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(URL(string: url)?.host() ?? "Link", systemImage: "globe")
                .font(.system(size: 14, weight: .semibold))
            Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
