import AppKit
import SlateCore
import SwiftUI

extension EnvironmentValues {
    /// The resolved theme for the current window.
    @Entry public var slateTheme: ResolvedTheme = ThemeEngine.builtInLight
}

public extension Color {
    init(_ hex: HexColor) {
        self.init(.sRGB, red: hex.red, green: hex.green, blue: hex.blue, opacity: hex.alpha)
    }
}

public extension NSColor {
    convenience init(_ hex: HexColor) {
        self.init(srgbRed: hex.red, green: hex.green, blue: hex.blue, alpha: hex.alpha)
    }
}

public extension NSFont {
    /// The named font, or a close stand-in if it isn't installed. Courier
    /// Prime isn't part of macOS, so Courier-family names fall back to
    /// Courier New, then Courier.
    static func slate(_ name: String, size: Double, weight: FontWeight = .regular) -> NSFont {
        let size = CGFloat(size)
        var candidates = [name]
        if name.localizedCaseInsensitiveContains("courier") {
            candidates += ["Courier New", "Courier"]
        }
        var font = candidates.lazy.compactMap { NSFont(name: $0, size: size) }.first
        if font == nil {
            switch name {
            case "SF Pro", "System": font = .systemFont(ofSize: size)
            case "SF Mono": font = .monospacedSystemFont(ofSize: size, weight: .regular)
            default: font = .systemFont(ofSize: size)
            }
        }
        guard var result = font else { return .systemFont(ofSize: size) }
        if weight == .bold || weight == .semibold {
            result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
        }
        return result
    }
}

/// Preference keys shared by the Settings window and every themed window.
public enum AppearancePreferences {
    public static let appearance = "appearance"
    public static let lightTheme = "lightTheme"
    public static let darkTheme = "darkTheme"
    /// Text size in the editors: 1 = the theme's sizes.
    public static let textScale = "textScale"
}

/// Resolves the theme for a window from the app settings (and an optional
/// per-project override), and applies it.
struct SlateThemeModifier: ViewModifier {
    @Environment(SlateAppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppearancePreferences.appearance) private var appearance = Appearance.system.rawValue
    @AppStorage(AppearancePreferences.lightTheme) private var lightTheme = "Light"
    @AppStorage(AppearancePreferences.darkTheme) private var darkTheme = "Dark"
    @AppStorage(AppearancePreferences.textScale) private var textScale = 1.0

    var projectOverride: String?

    func body(content: Content) -> some View {
        let settings = AppearanceSettings(
            appearance: Appearance(rawValue: appearance) ?? .system,
            lightTheme: lightTheme,
            darkTheme: darkTheme
        )
        let theme = model.themes.theme(isDark: colorScheme == .dark, settings: settings, projectOverride: projectOverride)
            .scaled(by: textScale)
        content
            .environment(\.slateTheme, theme)
            .tint(Color(theme.chrome.accent))
            .preferredColorScheme(preferredScheme(settings: settings, theme: theme))
    }

    private func preferredScheme(settings: AppearanceSettings, theme: ResolvedTheme) -> ColorScheme? {
        if projectOverride != nil, theme.name.lowercased() == projectOverride?.lowercased() {
            return theme.appearance == .dark ? .dark : .light
        }
        switch settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public extension View {
    /// Applies the app theme, or the project's theme if it names one.
    func slateThemed(projectOverride: String? = nil) -> some View {
        modifier(SlateThemeModifier(projectOverride: projectOverride))
    }
}
