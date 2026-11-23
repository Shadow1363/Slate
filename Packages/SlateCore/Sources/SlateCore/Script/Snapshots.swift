import Foundation

/// A line-by-line comparison of two texts.
public enum LineDiff {
    public struct Row: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case same, changed, added, removed }
        public var kind: Kind
        public var old: String?
        public var new: String?
    }

    /// Indices added in `new` and removed from `old`.
    public static func changes(old: [String], new: [String]) -> (inserted: Set<Int>, removed: Set<Int>) {
        var inserted: Set<Int> = [], removed: Set<Int> = []
        for change in new.difference(from: old) {
            switch change {
            case .insert(let offset, _, _): inserted.insert(offset)
            case .remove(let offset, _, _): removed.insert(offset)
            }
        }
        return (inserted, removed)
    }

    /// Side-by-side rows: unchanged lines pair up; a removal followed by an
    /// addition reads as one changed line.
    public static func rows(old: [String], new: [String]) -> [Row] {
        let (inserted, removed) = changes(old: old, new: new)
        var rows: [Row] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                if j < new.count, inserted.contains(j) {
                    rows.append(Row(kind: .changed, old: old[i], new: new[j]))
                    j += 1
                } else {
                    rows.append(Row(kind: .removed, old: old[i], new: nil))
                }
                i += 1
            } else if j < new.count, inserted.contains(j) {
                rows.append(Row(kind: .added, old: nil, new: new[j]))
                j += 1
            } else {
                if i < old.count, j < new.count { rows.append(Row(kind: .same, old: old[i], new: new[j])) }
                i += 1
                j += 1
            }
        }
        return rows
    }
}

/// A named copy of the act files in `script/.snapshots/<date> <name>/`.
public struct ScriptSnapshot: Sendable, Equatable, Identifiable {
    public static let folder = "script/.snapshots"

    /// The folder's name: `2026-11-23 1405 Before the ticket hut`.
    public let folderName: String
    public let url: URL

    public var id: String { folderName }

    /// The name after the date and time.
    public var name: String {
        let parts = folderName.split(separator: " ", maxSplits: 2)
        return parts.count == 3 ? String(parts[2]) : folderName
    }

    public var date: Date? {
        let parts = folderName.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        return Self.stampFormatter.date(from: parts[0] + " " + parts[1])
    }

    /// Its act files: (name, text), in name order.
    public func files() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { ["md", "fountain", "txt"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { (name: $0, text: try String(contentsOf: url.appending(path: $0), encoding: .utf8)) }
    }

    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()

    /// Every snapshot in a project, newest first.
    public static func all(in root: URL) -> [ScriptSnapshot] {
        let base = root.appending(path: folder, directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .map { ScriptSnapshot(folderName: $0, url: base.appending(path: $0, directoryHint: .isDirectory)) }
            .sorted { $0.folderName > $1.folderName }
    }

    /// Saves the given act files as a new snapshot.
    @discardableResult
    public static func save(name: String, files: [(name: String, text: String)], in root: URL, date: Date = .now) throws -> ScriptSnapshot {
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if title.isEmpty { title = "Snapshot" }
        let base = root.appending(path: folder, directoryHint: .isDirectory)
        var folderName = stampFormatter.string(from: date) + " " + title
        var n = 2
        while FileManager.default.fileExists(atPath: base.appending(path: folderName).path) {
            folderName = stampFormatter.string(from: date) + " " + title + " \(n)"
            n += 1
        }
        let url = base.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files { try CoordinatedFileIO.write(Data(file.text.utf8), to: url.appending(path: file.name)) }
        return ScriptSnapshot(folderName: folderName, url: url)
    }
}
