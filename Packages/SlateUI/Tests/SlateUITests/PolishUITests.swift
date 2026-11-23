import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SlateCore
@testable import SlateUI

@MainActor
@Suite("Polish")
struct PolishUITests {
    @Test func colourHexRoundTrip() {
        #expect(Color(hexString: "#F2C46D").hexString == "#F2C46D")
        #expect(Color(hexString: "#14161A80").hexString == "#14161A80")
        #expect(Color(hexString: "nope").hexString.hasSuffix("00"))
    }

    @Test func sampleFilmCopiesGetFreeNames() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SlateSample-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let showcase = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Showcase/Tidewater", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for expected in ["Tidewater", "Tidewater 2"] {
            let title = ProjectFolders.freeFolder(for: "Tidewater", in: folder).lastPathComponent
            let root = try ProjectCreator.create(title: title, template: .showcase, in: folder, sample: showcase)
            #expect(root.lastPathComponent == expected)
            // The snapshot and revision copies come along.
            #expect(!ScriptSnapshot.all(in: root).isEmpty)
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "script/revisions/01 blue").path))
        }
    }
}
