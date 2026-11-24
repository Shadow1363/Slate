import SwiftUI

// Slate's shared controls, so every area looks and behaves the same:
//
// - Toolbar: [left sidebar] Area ▾ [right sidebar] · the view's mode
//   picker in the centre · the area's actions (add, publish, settings).
//   Zoom never lives in the toolbar.
// - Item inspectors (a selected frame, event, pin): 280 pt beside the board.
// - Zoom: one pill at the bottom-left of every zoomable view (canvas,
//   map, timeline): − 100% + and fit.
// - Panel filter rows: borderless menus, scope on the left, filter on the right.

/// The zoom pill in the bottom-left corner of the canvas, map and timeline.
/// Its buttons carry the ⌘− / ⌘= / ⌘0 shortcuts.
struct ZoomControl: View {
    let percent: Int
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    var fit: (() -> Void)?
    var fitHelp = "Fit everything (⌘0)"
    var actualSize: (() -> Void)?
    var outTitle = "Zoom Out"
    var inTitle = "Zoom In"

    var body: some View {
        HStack(spacing: 2) {
            button(outTitle, "minus", action: zoomOut)
                .keyboardShortcut("-", modifiers: .command)
            Button {
                (actualSize ?? fit)?()
            } label: {
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 38)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(actualSize != nil ? "Zoom: pinch or ⌘-scroll. Click for 100% (⇧⌘0)." : "Zoom: pinch or ⌘-scroll.")
            .modifier(ActualSizeShortcut(enabled: actualSize != nil))
            button(inTitle, "plus", action: zoomIn)
                .keyboardShortcut("=", modifiers: .command)
            if let fit {
                Divider().frame(height: 14).padding(.horizontal, 2)
                button("Fit", "arrow.up.left.and.arrow.down.right", action: fit)
                    .keyboardShortcut("0", modifiers: .command)
                    .help(fitHelp)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.quaternary))
        .padding(12)
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ActualSizeShortcut: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut("0", modifiers: [.command, .shift]) } else { content }
    }
}

/// A board (storyboard, map, timeline) with the selected item's inspector
/// beside it, always 280 pt wide. A plain HStack, so the board gives way
/// instead of widening the window.
struct ItemInspectorLayout<Board: View, Inspector: View>: View {
    let showing: Bool
    @ViewBuilder let board: () -> Board
    @ViewBuilder let inspector: () -> Inspector

    var body: some View {
        HStack(spacing: 0) {
            board()
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            if showing {
                Divider()
                inspector()
                    .frame(width: 280)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// A borderless menu for a panel's filter row (scope, filter, order).
struct PanelMenu<Content: View>: View {
    let title: String
    var systemImage: String?
    var help: String = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(help)
    }
}

/// A panel's filter row: same height, padding and font everywhere.
struct PanelFilterBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
