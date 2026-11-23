import Foundation

/// A scene's board folder: `storyboard/scenes/s014 int-kitchen-night`.
public struct SceneFolder: Sendable, Equatable, Hashable, Identifiable {
    /// Relative to the project root.
    public let path: String

    public init(path: String) { self.path = path }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// The ID prefix (`s014`), the folder's real key.
    public var sceneID: String? { StoryboardFolders.sceneID(fromFolderName: name) }
    public var isOrphan: Bool { path.hasPrefix(StoryboardFolders.orphans + "/") }
    public var framesPath: String { path + "/" + FramesFile.name }
}

/// Keeps scene folders matched to the script's scenes. Pure planning: the
/// app carries out the moves.
public enum StoryboardFolders {
    public static let scenes = "storyboard/scenes"
    public static let orphans = "storyboard/orphans"
    public static let settings = "storyboard/storyboard.json"

    /// `s014 int-kitchen-night`.
    public static func folderName(sceneID: String, heading: String) -> String {
        sceneID + " " + Slug.make(heading)
    }

    /// The first word, if it looks like a scene ID (`s014`, `s014A`).
    public static func sceneID(fromFolderName name: String) -> String? {
        guard let first = name.split(whereSeparator: \.isWhitespace).first, first.count >= 2,
              first.first == "s", first.dropFirst().first?.isNumber == true else { return nil }
        return String(first)
    }

    /// Scene and orphan folders, from the project's file list (folders show up
    /// through the files inside them).
    public static func folders(in paths: [String]) -> [SceneFolder] {
        var found: Set<String> = []
        for path in paths {
            for root in [scenes, orphans] where path.hasPrefix(root + "/") {
                let rest = path.dropFirst(root.count + 1)
                guard let slash = rest.firstIndex(of: "/") else { continue }
                found.insert(root + "/" + rest[..<slash])
            }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(SceneFolder.init(path:))
    }

    public struct Plan: Sendable, Equatable {
        public struct Rename: Sendable, Equatable {
            public let from: String
            public let to: String
        }

        /// Scene ID → its folder.
        public var boarded: [String: SceneFolder] = [:]
        /// Folders whose name no longer matches the heading.
        public var renames: [Rename] = []
        /// Folders in `scenes/` whose scene isn't in the script (or that repeat an ID).
        public var missing: [SceneFolder] = []
        public var orphans: [SceneFolder] = []
        /// Scenes with no folder yet.
        public var unboarded: [String] = []
    }

    /// Matches folders to scenes (ID and heading, in script order).
    public static func plan(scenes: [(id: String, heading: String)], folders: [SceneFolder]) -> Plan {
        var plan = Plan()
        let headings = Dictionary(scenes.map { ($0.id, $0.heading) }, uniquingKeysWith: { first, _ in first })
        let taken = Set(folders.map { $0.path.lowercased() })
        // When two folders share an ID, the one already named for the heading wins.
        let ordered = folders.sorted { a, b in
            func exact(_ folder: SceneFolder) -> Bool {
                guard let id = folder.sceneID, let heading = headings[id] else { return false }
                return folder.name == folderName(sceneID: id, heading: heading)
            }
            return exact(a) && !exact(b)
        }
        for folder in ordered {
            if folder.isOrphan {
                plan.orphans.append(folder)
                continue
            }
            guard let id = folder.sceneID, let heading = headings[id], plan.boarded[id] == nil else {
                plan.missing.append(folder)
                continue
            }
            plan.boarded[id] = folder
            let wanted = Self.scenes + "/" + folderName(sceneID: id, heading: heading)
            if wanted != folder.path, !taken.contains(wanted.lowercased()) || wanted.lowercased() == folder.path.lowercased() {
                plan.renames.append(.init(from: folder.path, to: wanted))
            }
        }
        plan.unboarded = scenes.map(\.id).filter { plan.boarded[$0] == nil }
        return plan
    }

    /// Where a missing folder goes in `orphans/` (numbered if the name is taken).
    public static func orphanPath(for folder: SceneFolder, existing: Set<String>) -> String {
        orphans + "/" + StoryboardMedia.freeName(folder.name, existing: Set(existing.map { ($0 as NSString).lastPathComponent }))
    }
}

/// Frame guides for sketches.
public enum SketchGuide: String, Sendable, CaseIterable, Identifiable, Codable {
    case wide = "16:9"
    case scope = "2.39:1"
    case flat = "1.85:1"

    public var id: String { rawValue }

    /// Width ÷ height.
    public var ratio: Double {
        switch self {
        case .wide: 16.0 / 9.0
        case .scope: 2.39
        case .flat: 1.85
        }
    }
}

/// The strokes of a sketch, kept beside its PNG (`03.strokes.json`) so it can be edited again.
/// Points are 0–1 across the canvas (which has the guide's shape); widths are a share of its width.
public struct SketchStrokes: Sendable, Codable, Equatable {
    public struct Stroke: Sendable, Codable, Equatable {
        /// 0 is black, 1 is white.
        public var grey: Double
        public var width: Double
        public var erase: Bool
        /// `[x, y, pressure]`.
        public var points: [[Double]]

        public init(grey: Double, width: Double, erase: Bool = false, points: [[Double]] = []) {
            self.grey = grey
            self.width = width
            self.erase = erase
            self.points = points
        }
    }

    public static let suffix = ".strokes.json"

    public var version = 1
    public var guide: SketchGuide
    public var strokes: [Stroke]

    public init(guide: SketchGuide = .wide, strokes: [Stroke] = []) {
        self.guide = guide
        self.strokes = strokes
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(SketchStrokes.self, from: data)
    }

    /// Compact JSON (a sketch has thousands of points), keys sorted, three decimals.
    public var data: Data {
        var rounded = self
        for index in rounded.strokes.indices {
            rounded.strokes[index].points = rounded.strokes[index].points.map { $0.map { ($0 * 1000).rounded() / 1000 } }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(rounded)) ?? Data("{}".utf8)
    }
}
