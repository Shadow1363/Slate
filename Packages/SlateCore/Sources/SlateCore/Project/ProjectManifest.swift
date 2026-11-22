import Foundation

public enum PageSize: String, Codable, Sendable, CaseIterable {
    case letter
    case a4
}

public enum ManifestError: Error, Equatable, LocalizedError {
    case notAnObject
    case missingField(String)
    case invalidField(String, String)

    public var errorDescription: String? {
        switch self {
        case .notAnObject: "project.json must contain a JSON object."
        case .missingField(let field): "project.json is missing “\(field)”."
        case .invalidField(let field, let reason): "project.json has an invalid “\(field)”: \(reason)"
        }
    }
}

/// `project.json`: the file that marks a folder as a Slate project.
///
/// Keys Slate doesn't know are kept in `extra` and written back unchanged,
/// so hand edits and newer-version fields survive a save.
public struct ProjectManifest: Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var name: String
    public var id: String
    public var schemaVersion: Int
    public var pageSize: PageSize
    /// Name of a theme that overrides the app theme for this project.
    public var theme: String?
    public var settings: [String: JSONValue]
    public var extra: [String: JSONValue]

    private static let knownKeys: Set<String> = ["name", "id", "schemaVersion", "pageSize", "theme", "settings"]

    public init(
        name: String,
        id: String = ProjectManifest.newID(),
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        pageSize: PageSize = .letter,
        theme: String? = nil,
        settings: [String: JSONValue] = [:],
        extra: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.id = id
        self.schemaVersion = schemaVersion
        self.pageSize = pageSize
        self.theme = theme
        self.settings = settings
        self.extra = extra
    }

    public static func newID() -> String {
        "p-" + UUID().uuidString.lowercased()
    }

    public init(json: JSONValue) throws {
        guard case .object(let object) = json else { throw ManifestError.notAnObject }

        guard let nameValue = object["name"] else { throw ManifestError.missingField("name") }
        guard let name = nameValue.stringValue else { throw ManifestError.invalidField("name", "expected text") }

        guard let idValue = object["id"] else { throw ManifestError.missingField("id") }
        guard let id = idValue.stringValue, !id.isEmpty else { throw ManifestError.invalidField("id", "expected text") }

        guard let versionValue = object["schemaVersion"] else { throw ManifestError.missingField("schemaVersion") }
        guard let version = versionValue.intValue else { throw ManifestError.invalidField("schemaVersion", "expected a whole number") }

        var pageSize = PageSize.letter
        if let value = object["pageSize"] {
            guard let raw = value.stringValue, let parsed = PageSize(rawValue: raw.lowercased()) else {
                throw ManifestError.invalidField("pageSize", "expected \"letter\" or \"a4\"")
            }
            pageSize = parsed
        }

        var theme: String?
        if let value = object["theme"], value != .null {
            guard let raw = value.stringValue else { throw ManifestError.invalidField("theme", "expected a theme name") }
            theme = raw
        }

        var settings: [String: JSONValue] = [:]
        if let value = object["settings"] {
            guard let raw = value.objectValue else { throw ManifestError.invalidField("settings", "expected an object") }
            settings = raw
        }

        self.init(
            name: name,
            id: id,
            schemaVersion: version,
            pageSize: pageSize,
            theme: theme,
            settings: settings,
            extra: object.filter { !Self.knownKeys.contains($0.key) }
        )
    }

    public var json: JSONValue {
        var object = extra
        object["name"] = .string(name)
        object["id"] = .string(id)
        object["schemaVersion"] = .int(schemaVersion)
        object["pageSize"] = .string(pageSize.rawValue)
        object["settings"] = .object(settings)
        if let theme { object["theme"] = .string(theme) }
        return .object(object)
    }

    public static func decode(_ data: Data) throws -> ProjectManifest {
        let json: JSONValue
        do {
            json = try SlateJSON.decode(JSONValue.self, from: data)
        } catch {
            throw ManifestError.invalidField("file", "not valid JSON")
        }
        return try ProjectManifest(json: json)
    }

    public func encoded() throws -> Data {
        try SlateJSON.encode(json)
    }
}
