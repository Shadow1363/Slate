import Foundation

/// One `[[Target]]`, `[[Target|shown]]` or `[[Target#Heading]]` in a file.
public struct WikiLink: Sendable, Equatable, Codable {
    /// UTF-16 range of the whole link, brackets included.
    public let range: NSRange
    /// UTF-16 range of the target name only (what a rename replaces).
    public let targetRange: NSRange
    public let target: String
    public let heading: String?
    public let shown: String?

    /// The text a reader sees: the shown text, else the target.
    public var displayText: String { shown ?? target }

    /// Every link in `text`, skipping those inside `excluded` ranges (code).
    public static func find(in text: String, excluding excluded: [NSRange] = []) -> [WikiLink] {
        let ns = text as NSString
        var links: [WikiLink] = []
        for match in ScriptSpelling.linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            if excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            guard range.length > 4 else { continue }
            let inner = NSRange(location: range.location + 2, length: range.length - 4)
            let innerText = ns.substring(with: inner)
            var targetPart = innerText
            var shown: String?
            if let bar = innerText.firstIndex(of: "|") {
                targetPart = String(innerText[..<bar])
                shown = String(innerText[innerText.index(after: bar)...])
            }
            var heading: String?
            if let hash = targetPart.firstIndex(of: "#") {
                heading = String(targetPart[targetPart.index(after: hash)...])
                targetPart = String(targetPart[..<hash])
            }
            // Trim spaces inside the brackets but keep the range exact.
            let leading = targetPart.prefix { $0 == " " }.utf16.count
            let target = targetPart.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            links.append(WikiLink(
                range: range,
                targetRange: NSRange(location: inner.location + leading, length: target.utf16.count),
                target: target,
                heading: heading.map { $0.trimmingCharacters(in: .whitespaces) },
                shown: shown.map { $0.trimmingCharacters(in: .whitespaces) }
            ))
        }
        return links
    }

    /// The text to insert for a link to `name`.
    public static func text(for name: String, shown: String? = nil) -> String {
        if let shown, !shown.isEmpty, shown != name { return "[[\(name)|\(shown)]]" }
        return "[[\(name)]]"
    }

    /// The target written in a link field value such as `"[[Mara Voss]]"`.
    public static func target(inFieldValue value: String) -> String {
        find(in: value).first?.target ?? value.trimmingCharacters(in: .whitespaces)
    }
}

/// A universe note as the index sees it.
public struct Note: Sendable, Equatable, Codable, Identifiable {
    public let path: String
    public let noteID: String?
    public let type: String?
    public let name: String
    public let aliases: [String]
    public let tags: [String]
    public let fields: [YAMLField]
    /// Set when the frontmatter can't be read; `fields` is then empty.
    public let frontmatterError: String?
    public let headings: [MarkdownOutline.Heading]
    public let links: [WikiLink]

    public var id: String { path }

    /// File name without extension.
    public var fileStem: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public init(path: String, text: String) {
        self.path = path
        let split = Frontmatter.split(text)
        var fields: [YAMLField] = []
        var error: String?
        if let yaml = split.yaml {
            do {
                fields = try Frontmatter.parse(yaml)
            } catch let failure {
                error = (failure as? FrontmatterError)?.message ?? failure.localizedDescription
            }
        }
        self.frontmatterError = error
        func value(_ key: String) -> YAMLValue? { fields.first { $0.key == key }?.value }

        let outline = MarkdownOutline(parsing: split.body, offset: split.bodyOffset)
        let named = value("name")?.text ?? value("title")?.text ?? ""
        let h1 = outline.headings.first { $0.level == 1 }?.title ?? ""
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        self.name = !named.isEmpty ? named : !h1.isEmpty ? h1 : stem
        self.noteID = value("id").map(\.text).flatMap { $0.isEmpty ? nil : $0 }
        // `infobox: Character` (the wiki-infobox format) names the type too.
        self.type = (value("type") ?? value("infobox")).map(\.text).flatMap { $0.isEmpty ? nil : $0 }
        self.aliases = value("aliases")?.items ?? []
        self.tags = value("tags")?.items ?? []
        self.fields = fields
        self.headings = outline.headings
        self.links = WikiLink.find(in: text, excluding: outline.codeRanges)
    }

    public func value(_ key: String) -> YAMLValue? {
        fields.first { $0.key == key }?.value
    }

    /// The line under the name in the infobox (`subtitle:`).
    public var subtitle: String? {
        value("subtitle").map(\.text).flatMap { $0.isEmpty ? nil : $0 }
    }
}

