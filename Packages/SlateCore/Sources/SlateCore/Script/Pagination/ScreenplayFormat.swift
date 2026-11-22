import Foundation

/// Page geometry for Publish. Positions are in inches from the left edge of
/// the page; widths are in characters (Courier sets 10 per inch at 12 pt, so
/// counting characters is exact).
///
/// The defaults follow SPEC.md's Publish table, checked against the
/// fountain.io reference PDF of *Brick & Steel* (see DECISIONS.md).
public struct ScreenplayFormat: Sendable, Equatable {
    public struct Element: Sendable, Equatable {
        /// Left edge (or right edge for transitions), in inches.
        public var x: Double
        /// Wrap width in characters.
        public var width: Int
    }

    public var pageSize: PageSize
    public var pageWidth: Double
    public var pageHeight: Double
    public var topMargin: Double = 1
    public var bottomMargin: Double = 1
    public var fontSize: Double = 12
    public var linesPerInch: Double = 6

    public var heading = Element(x: 1.5, width: 61)
    public var action = Element(x: 1.5, width: 61)
    public var character = Element(x: 3.5, width: 38)
    public var parenthetical = Element(x: 2.9, width: 26)
    public var dialogue = Element(x: 2.5, width: 35)
    /// Transitions are right-aligned to this edge.
    public var transitionRightEdge: Double = 7.1
    /// Centred text is centred on this line (the middle of the action column).
    public var centerLine: Double = 4.5
    /// Dual dialogue: left and right column starts.
    public var dualColumns: (left: Double, right: Double) = (1.5, 4.6)
    public var dualWidth: Int = 28
    /// Blank lines before a scene heading (Final Draft's default is 2).
    public var headingSpacing: Int = 2
    /// Page number: right edge, and distance from the top of the page.
    public var pageNumberRightEdge: Double = 7.25
    public var pageNumberTop: Double = 0.5
    /// Scene numbers in the margins: left number's left edge, right number's left edge.
    public var sceneNumberLeft: Double = 0.75
    public var sceneNumberRight: Double = 7.35

    public init(pageSize: PageSize = .letter) {
        self.pageSize = pageSize
        switch pageSize {
        case .letter:
            pageWidth = 8.5
            pageHeight = 11
        case .a4:
            pageWidth = 8.27
            pageHeight = 11.69
        }
    }

    /// 54 on Letter, 58 on A4.
    public var linesPerPage: Int {
        Int(((pageHeight - topMargin - bottomMargin) * linesPerInch).rounded(.down))
    }

    /// Moves every horizontal position (used to match PDFs made with a
    /// narrower left margin).
    public func shifted(by inches: Double) -> ScreenplayFormat {
        var copy = self
        copy.heading.x += inches
        copy.action.x += inches
        copy.character.x += inches
        copy.parenthetical.x += inches
        copy.dialogue.x += inches
        copy.transitionRightEdge += inches
        copy.centerLine += inches
        copy.dualColumns = (dualColumns.left + inches, dualColumns.right + inches)
        return copy
    }

    public static func == (a: ScreenplayFormat, b: ScreenplayFormat) -> Bool {
        a.pageSize == b.pageSize && a.pageWidth == b.pageWidth && a.pageHeight == b.pageHeight
            && a.heading == b.heading && a.action == b.action && a.character == b.character
            && a.parenthetical == b.parenthetical && a.dialogue == b.dialogue
            && a.transitionRightEdge == b.transitionRightEdge && a.centerLine == b.centerLine
            && a.dualColumns == b.dualColumns && a.dualWidth == b.dualWidth && a.headingSpacing == b.headingSpacing
    }
}

/// Publish options stored in `project.json` under `settings.publish`.
public struct PublishSettings: Sendable, Equatable {
    /// Add (CONT'D) when a character speaks again after only action.
    public var autoContd = true
    /// Print scene numbers in both margins.
    public var sceneNumbers = true
    /// Render `*italic*`, `**bold**` and `_underline_` instead of printing the markers.
    public var emphasis = true
    public var pageSize: PageSize = .letter

    public init(autoContd: Bool = true, sceneNumbers: Bool = true, emphasis: Bool = true, pageSize: PageSize = .letter) {
        self.autoContd = autoContd
        self.sceneNumbers = sceneNumbers
        self.emphasis = emphasis
        self.pageSize = pageSize
    }

    public init(manifest: ProjectManifest) {
        let publish = manifest.settings["publish"]?.objectValue ?? [:]
        func flag(_ key: String) -> Bool {
            if case .bool(let value) = publish[key] { return value }
            return true
        }
        self.init(autoContd: flag("autoContd"), sceneNumbers: flag("sceneNumbers"), emphasis: flag("emphasis"), pageSize: manifest.pageSize)
    }

    /// Writes these settings back into a manifest, keeping other keys.
    public func apply(to manifest: inout ProjectManifest) {
        var publish = manifest.settings["publish"]?.objectValue ?? [:]
        publish["autoContd"] = .bool(autoContd)
        publish["sceneNumbers"] = .bool(sceneNumbers)
        publish["emphasis"] = .bool(emphasis)
        manifest.settings["publish"] = .object(publish)
        manifest.pageSize = pageSize
    }
}
