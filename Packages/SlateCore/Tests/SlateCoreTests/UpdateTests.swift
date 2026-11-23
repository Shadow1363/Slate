import Foundation
import Testing
@testable import SlateCore

@Suite("Updates")
struct UpdateTests {
    func v(_ text: String) -> AppVersion { AppVersion(text)! }

    @Test func versionsCompare() {
        #expect(v("0.9.0-beta.3") < v("0.9.0-beta.12"))
        #expect(v("0.9.0-beta.12") < v("0.9.0"))
        #expect(v("0.9.0") < v("0.9.1-beta.1"))
        #expect(v("v1.0") == v("1.0.0"))
        #expect(v("1.0.0-alpha") < v("1.0.0-beta"))
        #expect(v("1.0.0-beta") < v("1.0.0-beta.1"))
        #expect(AppVersion("nightly") == nil)
    }

    static let feed = """
    [
      {"tag_name": "v0.9.0-beta.14", "name": "Slate 0.9.0-beta.14", "prerelease": true, "draft": false, "body": "Notes 14",
       "html_url": "https://github.com/o/r/releases/tag/v0.9.0-beta.14", "published_at": "2026-11-24T10:00:00Z",
       "assets": [{"name": "Slate-0.9.0-beta.14.zip", "size": 8800000, "browser_download_url": "https://github.com/o/r/releases/download/v0.9.0-beta.14/Slate-0.9.0-beta.14.zip"}]},
      {"tag_name": "v0.9.0-beta.15", "name": "Draft", "prerelease": true, "draft": true, "assets": []},
      {"tag_name": "v0.9.0-beta.12", "prerelease": true, "draft": false,
       "assets": [{"name": "Slate-0.9.0-beta.12.zip", "size": 1, "browser_download_url": "https://x/Slate-0.9.0-beta.12.zip"}]},
      {"tag_name": "v0.8.0", "prerelease": false, "draft": false,
       "assets": [{"name": "Slate-0.8.0.zip", "size": 1, "browser_download_url": "https://x/Slate-0.8.0.zip"}]},
      {"tag_name": "v0.9.0-beta.13", "prerelease": true, "draft": false, "assets": [{"name": "notes.txt", "size": 1, "browser_download_url": "https://x/n"}]}
    ]
    """

    @Test func findsTheNewestRelease() throws {
        let data = Data(Self.feed.utf8)
        let update = try #require(try ReleaseFeed.update(from: data, current: v("0.9.0-beta.12"), includePrereleases: true))
        #expect(update.tag == "v0.9.0-beta.14")
        #expect(update.download.lastPathComponent == "Slate-0.9.0-beta.14.zip")
        #expect(update.notes == "Notes 14")
        #expect(update.date != nil)
        // Up to date, skipped, and betas turned off.
        #expect(try ReleaseFeed.update(from: data, current: v("0.9.0-beta.14"), includePrereleases: true) == nil)
        #expect(try ReleaseFeed.update(from: data, current: v("0.9.0-beta.12"), includePrereleases: true, skipping: "v0.9.0-beta.14") == nil)
        #expect(try ReleaseFeed.update(from: data, current: v("0.7.0"), includePrereleases: false)?.tag == "v0.8.0")
        #expect(ReleaseFeed.url(repository: "o/r")?.absoluteString == "https://api.github.com/repos/o/r/releases?per_page=20")
        #expect(ReleaseFeed.url(repository: "nope") == nil)
    }

    @Test func installScriptSwapsTheApp() throws {
        let folder = try TempFolder()
        let fm = FileManager.default
        let target = folder.url.appending(path: "Applications/Slate.app")
        let staged = folder.url.appending(path: "staging/Slate.app")
        for (url, marker) in [(target, "old"), (staged, "new")] {
            try fm.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: url.appending(path: "Contents/marker"))
        }
        let script = folder.url.appending(path: "install.sh")
        try Data(ReleaseFeed.installScript().utf8).write(to: script)
        // A process that has already gone stands in for Slate quitting.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [script.path, "999999", target.path, staged.path, "no-open"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: target.appending(path: "Contents/marker"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: target.path + ".updating"))
        #expect(!fm.fileExists(atPath: staged.deletingLastPathComponent().path))
    }
}
