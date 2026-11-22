import Foundation
import Observation

public enum ThemeError: Error, Equatable, LocalizedError {
    case notFound(String)
    case baseCycle(String)
    case invalid(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name): "There's no theme named “\(name)”."
        case .baseCycle(let name): "Theme “\(name)” has a base that leads back to itself."
        case .invalid(let name, let reason): "Theme “\(name)” is invalid: \(reason)"
        }
    }
}

/// Light, Dark or Follow System, and the theme picked for each.
public enum Appearance: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public struct AppearanceSettings: Sendable, Equatable {
    public var appearance: Appearance
    public var lightTheme: String
    public var darkTheme: String

    public init(appearance: Appearance = .system, lightTheme: String = "Light", darkTheme: String = "Dark") {
        self.appearance = appearance
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
    }
}

/// A theme file as written: any subset of tokens plus an optional `base`.
public struct ThemeSource: Sendable, Identifiable, Equatable {
    public let name: String
    public let isBuiltIn: Bool
    public let url: URL?
    public let json: JSONValue

    public var id: String { name.lowercased() }
}

/// Loads themes and resolves them to a full `ResolvedTheme`.
///
/// Built-ins (Light, Dark) ship in the package and are complete. User themes
/// in `~/Library/Application Support/Slate/Themes/*.slatetheme` can leave any
/// token out; it falls back to the theme named by `base`.
@MainActor
@Observable
public final class ThemeEngine {
    public nonisolated static let fileExtension = "slatetheme"

    public private(set) var themes: [ThemeSource] = []
    /// Problems with user theme files, one line each.
    public private(set) var loadErrors: [String] = []

    @ObservationIgnored private let userThemesDirectory: URL?

    public init(userThemesDirectory: URL?) {
        self.userThemesDirectory = userThemesDirectory
        reload()
    }

    public func reload() {
        var loaded = Self.builtInSources
        var errors: [String] = []
        if let userThemesDirectory,
           let urls = try? FileManager.default.contentsOfDirectory(at: userThemesDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in urls.filter({ $0.pathExtension == Self.fileExtension }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let source = try Self.source(at: url, isBuiltIn: false)
                    if loaded.contains(where: { $0.id == source.id }) {
                        errors.append("\(url.lastPathComponent): a theme named “\(source.name)” already exists.")
                    } else {
                        loaded.append(source)
                    }
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        themes = loaded
        loadErrors = errors
    }

    public func resolve(named name: String) throws -> ResolvedTheme {
        try Self.resolve(named: name, in: themes)
    }

    /// The theme a window should use. Falls back to the built-in for the
    /// appearance if the chosen theme can't be resolved.
    public func theme(isDark: Bool, settings: AppearanceSettings, projectOverride: String? = nil) -> ResolvedTheme {
        if let projectOverride, let theme = try? resolve(named: projectOverride) {
            return theme
        }
        let dark: Bool = switch settings.appearance {
        case .system: isDark
        case .light: false
        case .dark: true
        }
        let name = dark ? settings.darkTheme : settings.lightTheme
        return (try? resolve(named: name)) ?? (dark ? Self.builtInDark : Self.builtInLight)
    }

    // MARK: - Resolution

    nonisolated static func resolve(named name: String, in themes: [ThemeSource]) throws -> ResolvedTheme {
        let merged = try mergedJSON(named: name, in: themes, visited: [])
        do {
            let data = try SlateJSON.encoder().encode(merged)
            return try SlateJSON.decode(ResolvedTheme.self, from: data)
        } catch {
            throw ThemeError.invalid(name: name, reason: SlateJSON.describe(error))
        }
    }

    private nonisolated static func mergedJSON(named name: String, in themes: [ThemeSource], visited: Set<String>) throws -> JSONValue {
        guard let source = themes.first(where: { $0.id == name.lowercased() }) else {
            throw ThemeError.notFound(name)
        }
        guard !visited.contains(source.id) else { throw ThemeError.baseCycle(name) }
        guard let base = source.json["base"]?.stringValue else { return source.json }
        let baseJSON = try mergedJSON(named: base, in: themes, visited: visited.union([source.id]))
        return baseJSON.merging(source.json)
    }

    // MARK: - Loading

    nonisolated static func source(at url: URL, isBuiltIn: Bool) throws -> ThemeSource {
        let data = try Data(contentsOf: url)
        let json: JSONValue
        do {
            json = try SlateJSON.decode(JSONValue.self, from: data)
        } catch {
            throw ThemeError.invalid(name: url.deletingPathExtension().lastPathComponent, reason: "not valid JSON")
        }
        guard json.objectValue != nil else {
            throw ThemeError.invalid(name: url.lastPathComponent, reason: "expected a JSON object")
        }
        let name = json["name"]?.stringValue ?? url.deletingPathExtension().lastPathComponent
        return ThemeSource(name: name, isBuiltIn: isBuiltIn, url: url, json: json)
    }

    public nonisolated static let builtInSources: [ThemeSource] = {
        guard let folder = Bundle.module.url(forResource: "Themes", withExtension: nil) else {
            fatalError("SlateCore is missing its Themes resource folder.")
        }
        return ["light", "dark"].map { name in
            do {
                return try source(at: folder.appending(path: "\(name).\(fileExtension)"), isBuiltIn: true)
            } catch {
                fatalError("Built-in theme \(name) is unreadable: \(error)")
            }
        }
    }()

    public nonisolated static let builtInLight: ResolvedTheme = builtIn("Light")
    public nonisolated static let builtInDark: ResolvedTheme = builtIn("Dark")

    private nonisolated static func builtIn(_ name: String) -> ResolvedTheme {
        do {
            return try resolve(named: name, in: builtInSources)
        } catch {
            fatalError("Built-in theme \(name) doesn't resolve: \(error)")
        }
    }
}
