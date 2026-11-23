import AppKit
import SlateCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Appearance › Edit Themes…: duplicate a theme, change any token,
/// see it in a preview, share themes as `.slatetheme` files.
public struct ThemeEditorView: View {
    @Environment(SlateAppModel.self) private var model
    @State private var selection: String? = "Dark"
    @State private var error: String?

    public init() {}

    private var engine: ThemeEngine { model.themes }

    public var body: some View {
        HSplitView {
            themeList
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
            if let name = selection, let source = engine.source(named: name) {
                TokenList(engine: engine, source: source, error: $error)
                    .frame(minWidth: 380, idealWidth: 440)
                    .id(source.id)
                ThemePreview(theme: (try? engine.resolve(named: name)) ?? ThemeEngine.builtInLight)
                    .frame(minWidth: 320, idealWidth: 380)
            } else {
                ContentUnavailableView("Choose a Theme", systemImage: "paintpalette")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .alert("Couldn't change the theme", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var themeList: some View {
        VStack(spacing: 0) {
            List(engine.themes, selection: $selection) { theme in
                Label(theme.name, systemImage: theme.isBuiltIn ? "lock" : "paintpalette")
                    .tag(theme.name)
                    .help(theme.isBuiltIn ? "Built in: duplicate it to make changes" : (theme.url?.path ?? ""))
            }
            Divider()
            HStack(spacing: 4) {
                Button { run { selection = try engine.duplicate(named: selection ?? "Light") } } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate")
                    .accessibilityLabel("Duplicate Theme")
                Button { run { try engine.delete(named: selection ?? ""); selection = "Light" } } label: { Image(systemName: "minus") }
                    .help("Move to Trash")
                    .accessibilityLabel("Delete Theme")
                    .disabled(engine.source(named: selection ?? "")?.isBuiltIn ?? true)
                Spacer()
                Menu {
                    Button("Import…", action: importTheme)
                    Button("Export…", action: exportTheme).disabled(selection == nil)
                    Divider()
                    Button("Show Themes Folder") {
                        if let folder = engine.userThemesFolder {
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(folder)
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { self.error = error.localizedDescription }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ThemeEngine.fileExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { selection = try engine.importTheme(from: url) }
    }

    private func exportTheme() {
        guard let name = selection else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + "." + ThemeEngine.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try engine.export(named: name, to: url) }
    }
}

/// Every token of one theme, grouped as in SPEC's theme table.
private struct TokenList: View {
    let engine: ThemeEngine
    let source: ThemeSource
    @Binding var error: String?

    static let groups: [(key: String, title: String)] = [
        ("chrome", "App Chrome"), ("editor", "Editor"), ("script", "Screenplay Elements"), ("markdown", "Markdown"),
        ("margin", "Margin"), ("canvas", "Canvas, Timeline and Map"), ("storyboard", "Storyboard"),
    ]

    var body: some View {
        let tokens = (try? engine.tokens(of: source.name)) ?? []
        Form {
            if source.isBuiltIn {
                Text("Built-in themes can't be changed. Duplicate this one to make your own.")
                    .foregroundStyle(.secondary)
            } else if let base = source.json["base"]?.stringValue {
                Text("Anything you don't change comes from \(base).").foregroundStyle(.secondary)
            }
            ForEach(Self.groups, id: \.key) { group in
                let items = tokens.filter { $0.group == group.key }
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { token in
                            TokenRow(token: token, editable: !source.isBuiltIn) { value in
                                do { try engine.set(value, at: token.path, in: source.name) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One token: the right control for its kind, plus Reset when this theme sets it.
private struct TokenRow: View {
    let token: ThemeToken
    let editable: Bool
    let set: (JSONValue?) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                control.disabled(!editable)
                if editable, token.overridden {
                    Button { set(nil) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Reset to the base theme's value")
                        .accessibilityLabel("Reset \(token.title)")
                }
            }
        } label: {
            Text(token.title).fontWeight(token.overridden && editable ? .semibold : .regular)
        }
    }

    @ViewBuilder private var control: some View {
        switch token.kind {
        case .color:
            ColorPicker(token.title, selection: Binding(get: { Color(hexString: token.value.stringValue ?? "") },
                                                       set: { set(.string($0.hexString)) }))
                .labelsHidden()
        case .colorList:
            let items = token.value.arrayStrings
            HStack(spacing: 2) {
                ForEach(items.indices, id: \.self) { index in
                    ColorPicker("\(token.title) \(index + 1)", selection: Binding(get: { Color(hexString: items[index]) }, set: { color in
                        var list = items
                        list[index] = color.hexString
                        set(.array(list.map(JSONValue.string)))
                    }))
                    .labelsHidden()
                }
            }
        case .number:
            TextField(token.title, value: Binding(get: { token.value.numberValue ?? 0 }, set: { set(.double($0)) }),
                      format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
        case .font:
            FontPicker(name: token.value.stringValue ?? "", title: token.title) { set(.string($0)) }
        case .weight:
            Picker(token.title, selection: Binding(get: { token.value.stringValue ?? "regular" }, set: { set(.string($0)) })) {
                ForEach(FontWeight.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
        case .toggle:
            Toggle(token.title, isOn: Binding(get: { token.value == .bool(true) }, set: { set(.bool($0)) }))
                .labelsHidden()
        case .text:
            Text(token.value.stringValue ?? "—").foregroundStyle(.secondary)
        }
    }
}

/// A font family menu (installed families, plus the bundled Courier Prime).
private struct FontPicker: View {
    let name: String
    let title: String
    let set: (String) -> Void

    static let families: [String] = {
        var names = NSFontManager.shared.availableFontFamilies
        if !names.contains("Courier Prime") { names.append("Courier Prime") }
        return names.sorted()
    }()

    var body: some View {
        Picker(title, selection: Binding(get: { name }, set: { set($0) })) {
            if !Self.families.contains(name) { Text(name).tag(name) }
            ForEach(Self.families, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 200)
    }
}

/// A short script, a note and a margin to-do, in the theme's fonts and colours.
struct ThemePreview: View {
    let theme: ResolvedTheme

    private func line(_ text: String, _ style: ResolvedTheme.ElementStyle, indent: CGFloat = 0, align: Alignment = .leading) -> some View {
        Text(style.uppercase ? text.uppercased() : text)
            .font(Font(NSFont.slate(style.font, size: style.size, weight: style.weight)))
            .foregroundStyle(Color(style.color))
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: align)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    line("INT. KITCHEN - NIGHT", theme.script.sceneHeading)
                    line("Rain hammers the window. Mara stares at a brass key.", theme.script.action)
                    VStack(alignment: .leading, spacing: 0) {
                        line("MARA", theme.script.character, indent: 120)
                        line("(quietly)", theme.script.parenthetical, indent: 90)
                        line("I haven't opened it yet.", theme.script.dialogue, indent: 60)
                    }
                    line("CUT TO:", theme.script.transition, align: .trailing)
                    line("/* boneyard note */", theme.script.boneyard)
                }
                .padding(20)
                .background(Color(theme.editor.page))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 6) {
                    Text("The Brass Key").font(.system(size: theme.markdown.h1Size, weight: .bold)).foregroundStyle(Color(theme.markdown.heading))
                    (Text("Found under the floor. See ").foregroundStyle(Color(theme.markdown.text))
                        + Text("Time Loop Rules").foregroundStyle(Color(theme.markdown.wikiLink))
                        + Text(" and ").foregroundStyle(Color(theme.markdown.text))
                        + Text("Missing Note").foregroundStyle(Color(theme.markdown.brokenLink)).strikethrough())
                        .font(Font(NSFont.slate(theme.markdown.font, size: theme.markdown.size)))
                    Text("“The sea keeps what it's owed.”").italic().foregroundStyle(Color(theme.markdown.quote))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(theme.editor.background))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 6) {
                    Label("Fix Mara's motivation", systemImage: "circle").foregroundStyle(Color(theme.margin.todo))
                    Label("Check the key in act one", systemImage: "exclamationmark.circle").foregroundStyle(Color(theme.margin.overdue))
                    Label("Rename the courier", systemImage: "checkmark.circle.fill").foregroundStyle(Color(theme.margin.done))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(theme.margin.noteBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(16)
        }
        .background(Color(theme.chrome.windowBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme preview")
    }
}

private extension JSONValue {
    var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var arrayStrings: [String] {
        if case .array(let items) = self { return items.compactMap(\.stringValue) }
        return []
    }
}

extension Color {
    init(hexString: String) {
        if let hex = HexColor(hex: hexString) { self.init(hex) } else { self = .clear }
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> String { String(format: "%02X", Int((max(0, min(1, value)) * 255).rounded())) }
        let rgb = "#" + byte(color.redComponent) + byte(color.greenComponent) + byte(color.blueComponent)
        return color.alphaComponent < 0.999 ? rgb + byte(color.alphaComponent) : rgb
    }
}
