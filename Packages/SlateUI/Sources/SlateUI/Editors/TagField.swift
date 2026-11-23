import SlateCore
import SwiftUI

/// Tags as chips with ×, a field to add one (Return or comma), and the project's
/// matching tags to pick from.
struct TagField: View {
    let tags: [String]
    /// Every tag in the project, most used first.
    let known: [String]
    let onChange: ([String]) -> Void
    var placeholder = "Add tag"
    @State private var text = ""
    @FocusState private var focused: Bool

    private var matches: [String] {
        let prefix = Tags.normalize(text)
        return known.filter { !tags.contains($0) && (prefix.isEmpty || $0.hasPrefix(prefix) || $0.contains(prefix)) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text("#" + tag).font(.callout)
                        Button {
                            onChange(tags.filter { $0 != tag })
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
                }
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(width: 110)
                    .focused($focused)
                    .onSubmit { add(text) }
                    .onChange(of: text) { _, new in
                        if new.contains(",") { add(new.replacingOccurrences(of: ",", with: "")) }
                    }
                    .accessibilityLabel("Add a tag")
            }
            if focused, !matches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(matches, id: \.self) { tag in
                        Button("#" + tag) { add(tag) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func add(_ raw: String) {
        let tag = Tags.normalize(raw)
        text = ""
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        onChange(tags + [tag])
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
