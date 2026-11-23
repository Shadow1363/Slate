import SlateCore
import SwiftUI

/// The Search panel: a large field over the project window, results grouped
/// below. ↑/↓ choose, Return opens, Tab completes a bang or tag, Esc closes.
struct SpotlightPanel: View {
    @Bindable var model: SpotlightModel
    /// Closes the panel; true when a result was opened (so focus stays where it went).
    let close: (_ opened: Bool) -> Void
    @FocusState private var focused: Bool

    /// One selectable line.
    enum Row: Identifiable {
        case bang(Bang)
        case tag(String, Int)
        case recent(String)
        case item(SearchItem)
        case match(path: String, ProjectSearch.Match)

        var id: String {
            switch self {
            case .bang(let bang): "bang:" + bang.id
            case .tag(let tag, _): "tagsuggest:" + tag
            case .recent(let text): "recent:" + text
            case .item(let item): "item:" + item.id
            case .match(_, let match): "match:" + match.id
            }
        }
    }

    /// Groups of rows, in display order.
    private var groups: [(title: String, rows: [Row])] {
        var groups: [(String, [Row])] = []
        if !model.bangSuggestions.isEmpty { groups.append(("Bangs", model.bangSuggestions.map(Row.bang))) }
        if !model.tagSuggestions.isEmpty { groups.append(("Tags", model.tagSuggestions.map { Row.tag($0.tag, $0.count) })) }
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            if !model.recentSearches.isEmpty { groups.append(("Recent", model.recentSearches.map(Row.recent))) }
            return groups
        }
        for section in model.sections { groups.append((section.title, section.items.map(Row.item))) }
        let matches = model.textResults.flatMap { file in file.matches.map { Row.match(path: file.path, $0) } }
        if !matches.isEmpty { groups.append((model.isTextSearch ? "Text" : "In Text", matches)) }
        return groups
    }

    var body: some View {
        let groups = groups
        let rows = groups.flatMap(\.rows)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Search Slate — ! for bangs, # for tags", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { activate(rows, at: model.highlighted, keepOpen: false) }
                    .accessibilityLabel("Search")
                if model.searchingText { ProgressView().controlSize(.small) }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if !rows.isEmpty || !model.query.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                                Text(group.title.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                let start = rows.firstIndex { $0.id == group.rows.first?.id } ?? 0
                                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                                    let position = start + index
                                    RowView(row: row, highlighted: position == model.highlighted, number: position < 9 ? position + 1 : nil)
                                        .id(row.id)
                                        .contentShape(.rect)
                                        .onTapGesture { activate(rows, at: position, keepOpen: false) }
                                        .onHover { if $0 { model.highlighted = position } }
                                }
                            }
                            if rows.isEmpty, !model.searchingText {
                                Text("No matches. Type ! to see what you can search, or / to search all text.")
                                    .foregroundStyle(.secondary)
                                    .padding(16)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 440)
                    .onChange(of: model.highlighted) { _, index in
                        if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "choose")
                hint("↩", "open")
                hint("⇥", "complete")
                hint("!", "bangs")
                hint("#", "tags")
                hint("/", "all text")
                Spacer()
                hint("esc", "close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 680)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .defaultFocus($focused, true)
        .onAppear { focusField() }
        .onChange(of: focused) { _, isFocused in if !isFocused { focusField() } }
        .onKeyPress(.downArrow) {
            model.highlighted = min(model.highlighted + 1, max(rows.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.highlighted = max(model.highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.tab) {
            if let first = model.bangSuggestions.first { model.complete(with: "!" + first.name); return .handled }
            if let first = model.tagSuggestions.first { model.complete(with: "#" + first.tag); return .handled }
            return .ignored
        }
        .onKeyPress(.escape) {
            close(false)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            activate(rows, at: model.highlighted, keepOpen: press.modifiers.contains(.command))
            return .handled
        }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard press.modifiers.contains(.command), let digit = Int(press.characters), digit >= 1 else { return .ignored }
            activate(rows, at: digit - 1, keepOpen: false)
            return .handled
        }
    }

    /// The field takes the keyboard once the panel is on screen (the editor
    /// had it a moment ago, and an immediate request can be lost).
    private func focusField() {
        DispatchQueue.main.async {
            focused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if !focused { focused = true } }
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced().weight(.semibold))
            Text(text)
        }
    }

    /// Opens (or completes with) a row. ⌘Return keeps Search open.
    private func activate(_ rows: [Row], at index: Int, keepOpen: Bool) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .bang(let bang): model.complete(with: "!" + bang.name)
        case .tag(let tag, _): model.complete(with: "#" + tag)
        case .recent(let text): model.query = text
        case .item(let item):
            if model.open(item), !keepOpen { close(true) }
        case .match(_, let match):
            model.open(match)
            if !keepOpen { close(true) }
        }
    }

    private struct RowView: View {
        let row: Row
        let highlighted: Bool
        let number: Int?

        var body: some View {
            HStack(spacing: 10) {
                icon.frame(width: 22).foregroundStyle(highlighted ? .white : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    title.lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).lineLimit(1)
                            .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    }
                }
                Spacer(minLength: 8)
                if case .item(let item) = row, !item.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.tags.prefix(3), id: \.self) { tag in
                            Text("#" + tag).font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(highlighted ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary), in: .capsule)
                        }
                    }
                }
                if let number {
                    Text("⌘\(number)").font(.caption.monospacedDigit())
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(highlighted ? .white : .primary)
            .background(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(highlighted ? .isSelected : [])
        }

        @ViewBuilder private var icon: some View {
            switch row {
            case .bang: Image(systemName: "exclamationmark")
            case .tag: Image(systemName: "number")
            case .recent: Image(systemName: "clock.arrow.circlepath")
            case .item(let item): Image(systemName: item.icon)
            case .match: Image(systemName: "text.magnifyingglass")
            }
        }

        @ViewBuilder private var title: some View {
            switch row {
            case .bang(let bang):
                HStack(spacing: 8) {
                    Text("!" + bang.name).font(.body.monospaced().weight(.semibold))
                    Text(bang.title)
                }
            case .tag(let tag, _): Text("#" + tag)
            case .recent(let text): Text(text)
            case .item(let item): Text(item.title)
            case .match(_, let match): Text(Self.highlight(match))
            }
        }

        private var subtitle: String? {
            switch row {
            case .bang(let bang): bang.help
            case .tag(_, let count): "\(count) " + (count == 1 ? "item" : "items")
            case .recent: nil
            case .item(let item): item.subtitle
            case .match(let path, let match): "\((path as NSString).lastPathComponent) · line \(match.line + 1)"
            }
        }

        static func highlight(_ match: ProjectSearch.Match) -> AttributedString {
            let ns = match.snippet as NSString
            let range = NSIntersectionRange(match.snippetRange, NSRange(location: 0, length: ns.length))
            var text = AttributedString(ns.substring(to: range.location))
            var hit = AttributedString(ns.substring(with: range))
            hit.inlinePresentationIntent = .stronglyEmphasized
            text += hit
            text += AttributedString(ns.substring(from: NSMaxRange(range)))
            return text
        }
    }
}
