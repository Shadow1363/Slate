import Foundation
import Testing
@testable import SlateCore

@Suite("Atomic, coordinated file I/O")
struct CoordinatedFileIOTests {
    @Test func writesReplacesAndLeavesNoTempFiles() throws {
        let folder = try TempFolder()
        let url = folder.file("script/script.md")
        try CoordinatedFileIO.writeText("first", to: url)
        try CoordinatedFileIO.writeText("second", to: url)
        #expect(try CoordinatedFileIO.readText(url) == "second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.file("script").path) == ["script.md"])
    }

    @Test func rejectsNonUTF8() throws {
        let folder = try TempFolder()
        let url = folder.file("latin1.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)
        #expect(throws: FileIOError.notUTF8("latin1.txt")) { try CoordinatedFileIO.readText(url) }
    }
}

@Suite("Outside changes")
struct ExternalChangeResolverTests {
    @Test func unchangedWhenDiskMatchesLastRead() {
        #expect(ExternalChangeResolver.resolve(buffer: "edited", lastKnownDisk: "a", newDisk: "a") == .unchanged)
    }

    @Test func cleanBufferReloads() {
        #expect(ExternalChangeResolver.resolve(buffer: "a", lastKnownDisk: "a", newDisk: "b") == .reload("b"))
    }

    @Test func dirtyBufferConflicts() {
        #expect(ExternalChangeResolver.resolve(buffer: "mine", lastKnownDisk: "a", newDisk: "theirs") == .conflict("theirs"))
    }

    @Test func identicalEditsAreNotAConflict() {
        #expect(ExternalChangeResolver.resolve(buffer: "same", lastKnownDisk: "a", newDisk: "same") == .reload("same"))
    }

    @Test func deletionIsReported() {
        #expect(ExternalChangeResolver.resolve(buffer: "a", lastKnownDisk: "a", newDisk: nil) == .deletedOnDisk)
        #expect(ExternalChangeResolver.resolve(buffer: "mine", lastKnownDisk: "a", newDisk: nil) == .deletedOnDisk)
    }
}

@Suite("FileWatcher")
struct FileWatcherTests {
    @Test func reportsAnOutsideWrite() async throws {
        let folder = try TempFolder()
        let watcher = FileWatcher(rootURL: folder.url)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try folder.write("hello", to: "script/script.md")

        let batch = try await firstMatch(in: watcher.events) { $0.contains("script/script.md") }
        #expect(batch.contains("script/script.md"))
    }

    @Test func ignoresTheCacheFolder() async throws {
        let folder = try TempFolder()
        try FileManager.default.createDirectory(at: folder.file(".slate"), withIntermediateDirectories: true)
        let watcher = FileWatcher(rootURL: folder.url)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try folder.write("index", to: ".slate/index.json")
        try await Task.sleep(for: .milliseconds(300))
        try folder.write("marker", to: "marker.txt")

        let seen = SeenPaths()
        _ = try await firstMatch(in: watcher.events) { batch in
            seen.add(batch)
            return batch.contains("marker.txt")
        }
        #expect(!seen.all.contains { $0.hasPrefix(".slate") })
    }

    @Test func relativePathsDropIgnoredAndJunkFiles() {
        let watcher = FileWatcher(rootURL: URL(filePath: "/tmp/SlateRoot"))
        let root = canonicalPath(URL(filePath: "/tmp/SlateRoot"))
        #expect(watcher.relativePath(root + "/script/a.md") == "script/a.md")
        #expect(watcher.relativePath(root + "/.slate/index") == nil)
        #expect(watcher.relativePath(root + "/universe/.DS_Store") == nil)
        #expect(watcher.relativePath("/elsewhere/a.md") == nil)
        #expect(watcher.relativePath(root) == "")
    }
}

final class SeenPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func add(_ batch: Set<String>) {
        lock.withLock { paths.formUnion(batch) }
    }

    var all: Set<String> { lock.withLock { paths } }
}
