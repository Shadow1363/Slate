import Foundation

/// A scene's colour label in the navigator and storyboard: `{#s014 color=blue}`.
public enum SceneColor: String, Sendable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, pink, grey

    public var id: String { rawValue }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// sRGB 0–1.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .red: (0.91, 0.30, 0.27)
        case .orange: (0.96, 0.58, 0.20)
        case .yellow: (0.95, 0.80, 0.20)
        case .green: (0.36, 0.72, 0.36)
        case .blue: (0.27, 0.54, 0.92)
        case .purple: (0.62, 0.40, 0.85)
        case .pink: (0.93, 0.45, 0.67)
        case .grey: (0.55, 0.55, 0.58)
        }
    }
}

/// Edits whole scenes in act-file text: tag attributes, and moving scenes between files.
public enum SceneEditing {
    /// Sets (or with nil removes) `key=value` in the tag of the scene whose heading
    /// is on `headingLine`, keeping the ID and other attributes in order.
    public static func settingAttribute(_ key: String, to value: String?, headingLine: Int, in text: String) -> String {
        let parsed = ScriptParser.parse(text)
        guard parsed.lines.indices.contains(headingLine), let tag = parsed.lines[headingLine].tagRange,
              let id = parsed.scenes.first(where: { $0.headingLine == headingLine })?.sceneID else { return text }
        let ns = text as NSString
        let tagText = ns.substring(with: tag)
        // The attribute pairs in their written order, minus `key`.
        var pairs: [String] = []
        if let open = tagText.range(of: "{#"), let close = tagText.range(of: "}", options: .backwards) {
            let inner = tagText[open.upperBound..<close.lowerBound]
            pairs = inner.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init).filter { !$0.hasPrefix(key + "=") }
        }
        if let value, !value.isEmpty { pairs.append(key + "=" + value) }
        let replacement = " {#" + ([id] + pairs).joined(separator: " ") + "}"
        return ns.replacingCharacters(in: tag, with: replacement)
    }

    /// Takes scene `index` out of `text`: (the text without it, the scene's text ending in one blank line).
    public static func removingScene(_ index: Int, from text: String) -> (text: String, scene: String)? {
        let parsed = ScriptParser.parse(text)
        guard parsed.scenes.indices.contains(index) else { return nil }
        let ns = text as NSString
        let range = parsed.scenes[index].range
        var block = ns.substring(with: range)
        while let last = block.last, last.isNewline || last == " " || last == "\t" { block.removeLast() }
        var rest = ns.replacingCharacters(in: range, with: "")
        while rest.hasSuffix("\n\n\n") { rest.removeLast() }
        return (rest, block + "\n\n")
    }

    /// Puts a scene's text before scene `index` of `text` (at the end when `index` is past the last).
    public static func insertingScene(_ scene: String, at index: Int, in text: String) -> String {
        let parsed = ScriptParser.parse(text)
        let ns = text as NSString
        if parsed.scenes.indices.contains(index) {
            return ns.replacingCharacters(in: NSRange(location: parsed.scenes[index].range.location, length: 0), with: scene)
        }
        var base = text
        while let last = base.last, last.isNewline { base.removeLast() }
        let body = scene.hasSuffix("\n\n") ? String(scene.dropLast()) : scene
        return base.isEmpty ? body : base + "\n\n" + body
    }

    /// Scene IDs that repeat one used in an earlier act file, with new IDs
    /// (one list of edits per file, in ascending order).
    public static func crossFileDuplicates(in files: [ParsedScript]) -> [[ScriptEditing.TagEdit]] {
        var used = Set(files.flatMap { $0.scenes.compactMap(\.sceneID) })
        var seen: Set<String> = []
        return files.map { parsed in
            var edits: [ScriptEditing.TagEdit] = []
            var inFile: Set<String> = []
            for scene in parsed.scenes {
                guard let id = scene.sceneID, let tag = parsed.lines[scene.headingLine].tagRange else { continue }
                if seen.contains(id), !inFile.contains(id) {
                    let fresh = ScriptBook.nextSceneID(existing: used)
                    used.insert(fresh)
                    // Keep the tag's other attributes.
                    let line = parsed.lines[scene.headingLine].text as NSString
                    let local = NSRange(location: tag.location - parsed.lines[scene.headingLine].range.location, length: tag.length)
                    let replacement = line.substring(with: local).replacingOccurrences(of: "{#" + id, with: "{#" + fresh)
                    edits.append(ScriptEditing.TagEdit(range: tag, replacement: replacement, sceneID: fresh))
                } else {
                    inFile.insert(id)
                }
            }
            seen.formUnion(inFile)
            return edits
        }
    }
}
