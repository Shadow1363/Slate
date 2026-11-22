import Foundation
@testable import SlateCore

/// A fresh temp folder, deleted when the value is released.
final class TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "SlateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ path: String) -> URL { url.appending(path: path) }

    func write(_ text: String, to path: String) throws {
        let target = file(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: file(path), encoding: .utf8)
    }
}

enum Fixtures {
    /// `Fixtures/` at the repo root.
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent() // SlateCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // SlateCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo
        .appending(path: "Fixtures", directoryHint: .isDirectory)

    static let sampleProject = root.appending(path: "SampleProject", directoryHint: .isDirectory)

    /// Copies the sample project into `folder` so tests can change it.
    static func copySampleProject(into folder: TempFolder) throws -> URL {
        let destination = folder.url.appending(path: "SampleProject", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: sampleProject, to: destination)
        return destination
    }
}

struct TimeoutError: Error {}

/// Waits for the first element of `stream` that satisfies `predicate`.
func firstMatch<T: Sendable>(
    in stream: AsyncStream<T>,
    timeout: Duration = .seconds(3),
    where predicate: @escaping @Sendable (T) -> Bool
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where predicate(value) {
                return value
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next(), let value = result else { throw TimeoutError() }
        return value
    }
}

/// Polls `condition` on the main actor until it's true or the timeout passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}
