import Foundation

/// A colour written as `#RGB`, `#RRGGBB` or `#RRGGBBAA` in a theme file.
public struct HexColor: Codable, Sendable, Hashable, CustomStringConvertible {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    public let hex: String

    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        red = Double((rgb >> 16) & 0xFF) / 255
        green = Double((rgb >> 8) & 0xFF) / 255
        blue = Double(rgb & 0xFF) / 255
        alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.hex = hex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let color = HexColor(hex: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "“\(raw)” is not a hex colour like #1A2B3C")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public var description: String { hex }
}

public enum ThemeAppearance: String, Codable, Sendable {
    case light
    case dark
}

public enum FontWeight: String, Codable, Sendable, CaseIterable {
    case regular
    case medium
    case semibold
    case bold
}

/// A theme with every token filled in, after falling back through its `base`.
/// The JSON keys match the `.slatetheme` file format.
public struct ResolvedTheme: Codable, Sendable, Equatable {
    public var name: String
    public var appearance: ThemeAppearance
    public var chrome: Chrome
    public var editor: Editor
    public var script: Script
    public var markdown: Markdown
    public var margin: Margin
    public var canvas: Canvas
    public var storyboard: Storyboard

    public struct Chrome: Codable, Sendable, Equatable {
        public var windowBackground: HexColor
        public var sidebarBackground: HexColor
        public var accent: HexColor
        public var selection: HexColor
        public var separator: HexColor
        public var toolbar: HexColor
    }

    public struct Editor: Codable, Sendable, Equatable {
        public var background: HexColor
        public var page: HexColor
        public var text: HexColor
        public var caret: HexColor
        public var selection: HexColor
        public var currentLine: HexColor
        public var spellError: HexColor
        /// The dotted underline under words defined in the dictionary.
        public var termUnderline: HexColor
        public var font: String
        public var size: Double
        public var lineSpacing: Double
        /// Width of the text column in points.
        public var pageWidth: Double
    }

    public struct ElementStyle: Codable, Sendable, Equatable {
        public var font: String
        public var size: Double
        public var weight: FontWeight
        public var color: HexColor
        public var uppercase: Bool
        /// Blank space above the element, in lines.
        public var spaceBefore: Double
    }

    public struct Script: Codable, Sendable, Equatable {
        public var sceneHeading: ElementStyle
        public var action: ElementStyle
        public var character: ElementStyle
        public var parenthetical: ElementStyle
        public var dialogue: ElementStyle
        public var transition: ElementStyle
        public var centered: ElementStyle
        public var boneyard: ElementStyle
        public var sceneChip: ElementStyle
    }

    public struct Markdown: Codable, Sendable, Equatable {
        public var font: String
        public var size: Double
        public var h1Size: Double
        public var h2Size: Double
        public var h3Size: Double
        public var text: HexColor
        public var heading: HexColor
        public var emphasis: HexColor
        public var link: HexColor
        public var wikiLink: HexColor
        public var brokenLink: HexColor
        public var codeFont: String
        public var codeBackground: HexColor
        public var quote: HexColor
        public var checkbox: HexColor
    }

    public struct Margin: Codable, Sendable, Equatable {
        public var todo: HexColor
        public var done: HexColor
        public var overdue: HexColor
        public var noteBackground: HexColor
        public var anchorHighlight: HexColor
    }

    public struct Canvas: Codable, Sendable, Equatable {
        public var textCard: HexColor
        public var noteCard: HexColor
        public var sceneCard: HexColor
        public var imageCard: HexColor
        public var groupFill: HexColor
        public var connector: HexColor
        public var jumpArc: HexColor
        public var pin: HexColor
        public var laneColors: [HexColor]
        public var branchColors: [HexColor]
    }

    public struct Storyboard: Codable, Sendable, Equatable {
        public var background: HexColor
        public var frameBorder: HexColor
        public var selectedFrame: HexColor
        public var overlayText: HexColor
    }
}
