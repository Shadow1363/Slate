import Foundation

/// Starting points for New Project. They differ only in starter files.
public enum ProjectTemplate: String, CaseIterable, Sendable, Identifiable {
    case feature
    case short
    case tvPilot
    case blank

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .feature: "Feature"
        case .short: "Short"
        case .tvPilot: "TV Pilot"
        case .blank: "Blank"
        }
    }

    public var summary: String {
        switch self {
        case .feature: "Three act files, note folders and a title page."
        case .short: "One script file, note folders and a title page."
        case .tvPilot: "A teaser and four act files, note folders and a title page."
        case .blank: "The bare folders and an empty script."
        }
    }

    /// Every template gets these, so the project always matches the folder format.
    static let baseFolders = [
        "universe",
        "script/margin",
        "storyboard/scenes",
        "storyboard/orphans",
        "dictionary",
        "templates",
        "exports",
        ".slate",
    ]

    /// One folder per note type, plus the visual tools.
    static let noteFolders = [
        "universe/characters",
        "universe/locations",
        "universe/rules",
        "universe/factions",
        "universe/items",
        "universe/events",
        "universe/canvases",
        "universe/timelines",
        "universe/maps",
    ]

    public var folders: [String] {
        self == .blank ? Self.baseFolders : Self.baseFolders + Self.noteFolders
    }

    /// Relative path → file contents, not counting `project.json`.
    public func starterFiles(title: String, date: Date) -> [String: String] {
        var files: [String: String] = [
            "universe/draft.md": "# \(title)\n\n",
            "script/margin/todos.md": "",
            "script/margin/notes.md": "",
            "storyboard/storyboard.json": Self.emptyStoryboard,
            "dictionary/words.md": WordBook.starter,
        ]
        files["script/title-page.md"] = titlePage(title: title, date: date)
        for (name, label) in actFiles {
            files["script/\(name)"] = label.map { "# \($0)\n\n" } ?? ""
        }
        return files
    }

    static var emptyStoryboard: String {
        let json = JSONValue.object(["scenes": .array([]), "settings": .object([:])])
        let data = (try? SlateJSON.encode(json)) ?? Data("{}\n".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// File name → the Fountain section (`# ACT ONE`) that opens it (nil for none).
    private var actFiles: [(String, String?)] {
        switch self {
        case .feature:
            [("01-act-one.md", "ACT ONE"), ("02-act-two.md", "ACT TWO"), ("03-act-three.md", "ACT THREE")]
        case .short:
            [("script.md", nil)]
        case .tvPilot:
            [
                ("01-teaser.md", "TEASER"), ("02-act-one.md", "ACT ONE"), ("03-act-two.md", "ACT TWO"),
                ("04-act-three.md", "ACT THREE"), ("05-act-four.md", "ACT FOUR"),
            ]
        case .blank:
            [("script.md", nil)]
        }
    }

    private func titlePage(title: String, date: Date) -> String {
        if self == .blank {
            return "Title: \(title)\n"
        }
        let draftDate = date.formatted(.dateTime.year().month(.wide).day())
        return """
        Title: \(title)
        Credit: written by
        Author:
        Draft date: \(draftDate)
        Contact:

        """
    }
}
