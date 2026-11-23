#if DEBUG
import AppKit
import SlateCore
import SwiftUI

/// Debug builds only: with `SLATE_SCREENSHOTS=<folder>` set, Slate opens a fresh
/// Tidewater copy, steps through its areas and, at each step, writes
/// `<name> <window number>` to `<folder>/steps.log` and waits for
/// `<folder>/<name>.done`. `Scripts/screenshots.sh` takes the pictures
/// (Slate itself never records the screen).
@MainActor
enum ScreenshotTour {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["SLATE_SCREENSHOTS"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    struct Step {
        let name: String
        let apply: @MainActor (ProjectSession) -> Void
    }

    static let steps: [Step] = [
        Step(name: "script") { session in
            session.area = .script
            session.script.showingPages = false
            session.script.showingMargin = true
            if let scene = session.script.scene(withID: "s001") { session.open(scene: scene) }
        },
        Step(name: "script-pages") { session in
            session.script.showingPages = true
        },
        Step(name: "storyboard") { session in
            session.script.showingPages = false
            session.area = .storyboard
            session.storyboard.focusedRow = "s001"
        },
        Step(name: "universe-note") { session in
            let juno = "universe/characters/juno-hale.md"
            if let note = session.links.graph.notes.first(where: { $0.path == juno }) {
                session.outline.expandAll(juno, tree: HeadingTree.build(note.headings, droppingTitle: note.name))
            }
            session.area = .universe
            session.universeSelection = juno
        },
        Step(name: "canvas") { session in
            session.universeSelection = "universe/canvases/story-web.canvas"
        },
        Step(name: "timeline") { session in
            session.universeSelection = session.timelineFiles.first
        },
        Step(name: "map") { session in
            session.universeSelection = session.mapFiles.first { $0.contains("saltmarrow") } ?? session.mapFiles.first
        },
        Step(name: "dictionary") { session in
            session.area = .dictionary
        },
        Step(name: "todo-comment") { session in
            session.closeSearch()
            let juno = "universe/characters/juno-hale.md"
            if let document = try? session.store.document(at: juno), !document.text.contains("TODO:") {
                document.text = document.text.replacingOccurrences(
                    of: "To stop living in 1987.",
                    with: "To stop living in 1987. %% TODO: does she ever say it out loud? due:2026-12-01 %%")
            }
            session.area = .universe
            session.universeSelection = juno
        },
        Step(name: "search") { session in
            session.area = .universe
            session.universeSelection = "universe/characters/juno-hale.md"
            session.showSearch("!c #good ")
        },
    ]

    /// Makes the project and opens its window; the tour runs once its session registers.
    static func start(model: SlateAppModel, open: @escaping (URL) -> Void) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let parent = FileManager.default.temporaryDirectory.appending(path: "SlateTour-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let root = try ProjectCreator.create(title: "Tidewater", template: .showcase, in: parent, sample: ProjectCreator.bundledShowcase)
            log("progress created \(root.path)", in: folder)
            open(root)
            Task { @MainActor in await run(model: model, root: root, folder: folder) }
        } catch {
            log("error \(error.localizedDescription)", in: folder)
            NSApp.terminate(nil)
        }
    }

    private static func run(model: SlateAppModel, root: URL, folder: URL) async {
        log("progress waiting", in: folder)
        var session: ProjectSession?
        for _ in 0..<100 where session == nil {
            try? await Task.sleep(for: .milliseconds(200))
            session = model.openSession(for: root) ?? model.openSession(for: root.resolvingSymlinksInPath())
        }
        log("progress session \(session != nil)", in: folder)
        guard let session else {
            log("error no project window", in: folder)
            NSApp.terminate(nil)
            return
        }
        try? await Task.sleep(for: .seconds(1))
        // Only the project window (the one that isn't Home), at a size that reads well in a README.
        let candidates = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && $0.title != "Slate" }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            log("error no window: " + NSApp.windows.map { "\($0.title)|\($0.isVisible)" }.joined(separator: ", "), in: folder)
            NSApp.terminate(nil)
            return
        }
        for other in NSApp.windows where other !== window && other.isVisible { other.orderOut(nil) }
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let size = NSSize(width: min(1440, screen.width - 40), height: min(900, screen.height - 40))
        window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        for step in steps {
            step.apply(session)
            try? await Task.sleep(for: .seconds(2))
            log("\(step.name) \(window.windowNumber)", in: folder)
            let done = folder.appending(path: step.name + ".done")
            for _ in 0..<150 where !FileManager.default.fileExists(atPath: done.path) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        log("finished", in: folder)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        NSApp.terminate(nil)
    }

    private static func log(_ line: String, in folder: URL) {
        let url = folder.appending(path: "steps.log")
        let text = ((try? String(contentsOf: url, encoding: .utf8)) ?? "") + line + "\n"
        try? Data(text.utf8).write(to: url)
    }
}
#endif
