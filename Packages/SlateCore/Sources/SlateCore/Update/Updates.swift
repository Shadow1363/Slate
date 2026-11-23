import Foundation

/// A version such as `0.9.0`, `0.9.0-beta.12` or `v1.2`. Betas sort before the
/// release they lead to: `0.9.0-beta.3 < 0.9.0-beta.12 < 0.9.0`.
public struct AppVersion: Sendable, Comparable, CustomStringConvertible {
    public let numbers: [Int]
    /// `["beta", 12]` as strings; empty for a release.
    public let prerelease: [String]
    public let text: String

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        self.text = text
    }

    public var description: String { text }
    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        for i in 0..<count {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        // Same numbers: a prerelease comes before the release.
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A GitHub release with a Slate zip attached.
public struct AppRelease: Sendable, Equatable {
    public let version: AppVersion
    public let tag: String
    public let title: String
    public let notes: String
    public let page: URL?
    public let download: URL
    public let size: Int
    public let date: Date?

    public static func == (a: AppRelease, b: AppRelease) -> Bool { a.tag == b.tag && a.download == b.download }
}

public enum ReleaseFeed {
    /// `https://api.github.com/repos/<owner>/<repo>/releases`.
    public static func url(repository: String) -> URL? {
        let parts = repository.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases?per_page=20")
    }

    /// Releases in GitHub's JSON that have a `Slate-….zip`, newest version first.
    /// Drafts are skipped, and prereleases unless `includePrereleases`.
    public static func releases(from data: Data, includePrereleases: Bool) throws -> [AppRelease] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let dates = ISO8601DateFormatter()
        var result: [AppRelease] = []
        for item in list {
            guard item["draft"] as? Bool != true,
                  includePrereleases || item["prerelease"] as? Bool != true,
                  let tag = item["tag_name"] as? String, let version = AppVersion(tag),
                  let assets = item["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String).map { $0.hasPrefix("Slate") && $0.hasSuffix(".zip") } ?? false }),
                  let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
            else { continue }
            result.append(AppRelease(
                version: version, tag: tag,
                title: item["name"] as? String ?? tag,
                notes: item["body"] as? String ?? "",
                page: (item["html_url"] as? String).flatMap(URL.init(string:)),
                download: link, size: asset["size"] as? Int ?? 0,
                date: (item["published_at"] as? String).flatMap(dates.date(from:))
            ))
        }
        return result.sorted { $0.version > $1.version }
    }

    /// The newest release after `current` (and not the skipped one), if any.
    public static func update(from data: Data, current: AppVersion, includePrereleases: Bool, skipping: String? = nil) throws -> AppRelease? {
        try releases(from: data, includePrereleases: includePrereleases)
            .first { $0.version > current && $0.tag != skipping }
    }

    /// The shell script that swaps the app once Slate has quit, then reopens it.
    /// If the copy fails, the old app is put back.
    public static func installScript() -> String {
        """
        #!/bin/bash
        # Slate's updater: waits for Slate to quit, replaces it, opens the new one.
        PID="$1"; TARGET="$2"; NEW="$3"; OPEN="${4:-open}"
        for _ in $(seq 1 600); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        BACKUP="$TARGET.updating"
        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP" && ditto "$NEW" "$TARGET"; then
            rm -rf "$BACKUP"
        else
            rm -rf "$TARGET"
            mv "$BACKUP" "$TARGET"
        fi
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        rm -rf "$(dirname "$NEW")"
        if [ "$OPEN" = "open" ]; then open "$TARGET"; fi

        """
    }
}
