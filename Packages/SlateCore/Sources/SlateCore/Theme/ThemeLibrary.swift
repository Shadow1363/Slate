import Foundation

/// One themeable value: where it sits in the theme file (`script.sceneHeading.color`),
/// what it resolves to, and whether this theme sets it itself.
public struct ThemeToken: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case color, colorList, number, font, weight, toggle, text }

    public let path: [String]
    public let value: JSONValue
    public let overridden: Bool

    public var id: String { path.joined(separator: ".") }
    /// The group it belongs to (`script`, `editor`…).
    public var group: String { path.first ?? "" }

    public var kind: Kind {
        switch value {
        case .string(let text) where HexColor(hex: text) != nil: .color
        case .array(let items) where items.allSatisfy({ $0.stringValue.flatMap(HexColor.init(hex:)) != nil }): .colorList
        case .string where path.last == "weight": .weight
        case .string where path.last?.lowercased().contains("font") == true: .font
        case .int, .double: .number
        case .bool: .toggle
        default: .text
        }
    }

    /// `Scene Heading › Color`.
    public var title: String {
        path.dropFirst().map(Self.words).joined(separator: " › ")
    }

    static func words(_ key: String) -> String {
        var result = ""
        for character in key {
            if character.isUppercase, !result.isEmpty { result += " " }
            result.append(result.isEmpty ? Character(character.uppercased()) : character)
        }
        return result
    }
}

/// Theme files: duplicate, edit tokens, delete, import and export. Built-ins are read-only.
extension ThemeEngine {
    public var userThemesFolder: URL? { userThemesDirectory }

    public func source(named name: String) -> ThemeSource? {
        themes.first { $0.id == name.lowercased() }
    }

    /// Every token of a theme, resolved through its base, in file order of groups.
    public func tokens(of name: String) throws -> [ThemeToken] {
        guard let source = source(named: name) else { throw ThemeError.notFound(name) }
        let resolved = try resolve(named: name)
        let json = try SlateJSON.decode(JSONValue.self, from: SlateJSON.encode(resolved))
        var tokens: [ThemeToken] = []
        func walk(_ value: JSONValue, _ path: [String]) {
            if case .object(let object) = value {
                for key in object.keys.sorted() { walk(object[key]!, path + [key]) }
            } else if !path.isEmpty, !["name", "appearance"].contains(path[0]) {
                tokens.append(ThemeToken(path: path, value: value, overridden: source.isBuiltIn || Self.value(at: path, in: source.json) != nil))
            }
        }
        walk(json, [])
        let order = ["chrome", "editor", "script", "markdown", "margin", "canvas", "storyboard"]
        return tokens.sorted { (order.firstIndex(of: $0.group) ?? 99, $0.id) < (order.firstIndex(of: $1.group) ?? 99, $1.id) }
    }

    static func value(at path: [String], in json: JSONValue) -> JSONValue? {
        var current: JSONValue? = json
        for key in path { current = current?[key] }
        return current
    }

    static func setting(_ value: JSONValue?, at path: [String], in json: JSONValue) -> JSONValue {
        guard let key = path.first else { return value ?? json }
        var object = json.objectValue ?? [:]
        if path.count == 1 {
            object[key] = value
        } else {
            let child = setting(value, at: Array(path.dropFirst()), in: object[key] ?? .object([:]))
            // Drop groups that end up empty.
            object[key] = child.objectValue?.isEmpty == true ? nil : child
        }
        return .object(object)
    }

    /// A free name: `Night Draft`, `Night Draft 2`…
    public func freeName(_ name: String) -> String {
        var candidate = name, n = 2
        while source(named: candidate) != nil {
            candidate = "\(name) \(n)"
            n += 1
        }
        return candidate
    }

    /// A new user theme based on `name`: just a name and a base, so every token
    /// falls back until it's changed. Returns the new theme's name.
    @discardableResult
    public func duplicate(named name: String) throws -> String {
        guard let original = source(named: name) else { throw ThemeError.notFound(name) }
        let newName = freeName(original.name + " Copy")
        var json: JSONValue = original.isBuiltIn ? .object(["base": .string(original.name)]) : original.json
        json = Self.setting(.string(newName), at: ["name"], in: json)
        try write(json, name: newName)
        return newName
    }

    /// Sets one token on a user theme (nil puts it back to the base's value).
    public func set(_ value: JSONValue?, at path: [String], in name: String) throws {
        guard let source = source(named: name), !source.isBuiltIn else { throw ThemeError.invalid(name: name, reason: "built-in themes can't be changed; duplicate it first") }
        let json = Self.setting(value, at: path, in: source.json)
        // Validate before saving, so a theme never becomes unreadable.
        var trial = themes.filter { $0.id != source.id }
        trial.append(ThemeSource(name: source.name, isBuiltIn: false, url: source.url, json: json))
        _ = try Self.resolve(named: source.name, in: trial)
        try write(json, name: source.name, url: source.url)
    }

    /// Moves a user theme's file to the Trash.
    public func delete(named name: String) throws {
        guard let source = source(named: name), !source.isBuiltIn, let url = source.url else { throw ThemeError.notFound(name) }
        try CoordinatedFileIO.trash(url)
        reload()
    }

    /// Copies a `.slatetheme` into the themes folder (renamed if the name is taken). Returns its name.
    @discardableResult
    public func importTheme(from url: URL) throws -> String {
        let incoming = try Self.source(at: url, isBuiltIn: false)
        let name = freeName(incoming.name)
        try write(Self.setting(.string(name), at: ["name"], in: incoming.json), name: name)
        return name
    }

    /// Writes a theme as a `.slatetheme` file to share.
    public func export(named name: String, to url: URL) throws {
        guard let source = source(named: name) else { throw ThemeError.notFound(name) }
        try CoordinatedFileIO.write(try SlateJSON.encode(source.json), to: url)
    }

    private func write(_ json: JSONValue, name: String, url: URL? = nil) throws {
        guard let folder = userThemesDirectory else { throw ThemeError.invalid(name: name, reason: "there's no themes folder") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = ProjectCreator.folderName(for: name) + "." + Self.fileExtension
        try CoordinatedFileIO.write(try SlateJSON.encode(json), to: url ?? folder.appending(path: fileName))
        reload()
    }
}

extension ResolvedTheme {
    /// Every text size multiplied by `factor` (Settings › Appearance › Text size).
    public func scaled(by factor: Double) -> ResolvedTheme {
        guard factor != 1, factor > 0 else { return self }
        var theme = self
        func scale(_ style: inout ElementStyle) { style.size = (style.size * factor * 2).rounded() / 2 }
        scale(&theme.script.sceneHeading)
        scale(&theme.script.action)
        scale(&theme.script.character)
        scale(&theme.script.parenthetical)
        scale(&theme.script.dialogue)
        scale(&theme.script.transition)
        scale(&theme.script.centered)
        scale(&theme.script.boneyard)
        scale(&theme.script.sceneChip)
        theme.editor.size *= factor
        theme.markdown.size *= factor
        theme.markdown.h1Size *= factor
        theme.markdown.h2Size *= factor
        theme.markdown.h3Size *= factor
        return theme
    }
}
