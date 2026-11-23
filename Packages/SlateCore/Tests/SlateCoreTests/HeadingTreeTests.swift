import Foundation
import Testing
@testable import SlateCore

@Suite("Heading index")
struct HeadingTreeTests {
    static func outline(_ text: String) -> [MarkdownOutline.Heading] { MarkdownOutline(parsing: text).headings }

    static func shape(_ nodes: [HeadingTree.Node]) -> [String] {
        nodes.flatMap { ["\($0.key)"] + shape($0.children) }
    }

    @Test func nestsUnderTheNearestHigherHeading() {
        let tree = HeadingTree.build(Self.outline("# Mara\n\n## Want\n\n### Now\n\n#### Today\n\n## Need\n\n### Later\n"), droppingTitle: "Mara")
        #expect(tree.map(\.heading.title) == ["Want", "Need"])
        #expect(Self.shape(tree) == ["Want", "Want/Now", "Want/Now/Today", "Need", "Need/Later"])
    }

    @Test func skippedLevelsAndNotesStartingLow() {
        // H1 then H3: the H3 still sits under the H1.
        var tree = HeadingTree.build(Self.outline("# Top\n\n### Deep\n\n## Middle\n"))
        #expect(Self.shape(tree) == ["Top", "Top/Deep", "Top/Middle"])
        // Starting at H3, then an H2: both top level, the H3 not under anything.
        tree = HeadingTree.build(Self.outline("### Small\n\n## Bigger\n\n### Inside\n"))
        #expect(tree.map(\.heading.title) == ["Small", "Bigger"])
        #expect(tree[1].children.map(\.heading.title) == ["Inside"])
    }

    @Test func keysAreStableAndUnique() {
        let before = HeadingTree.build(Self.outline("## Ghost\n\n### 1987\n\n## Notes\n\n## Notes\n"))
        #expect(Self.shape(before) == ["Ghost", "Ghost/1987", "Notes", "Notes #2"])
        // A heading added above doesn't change the others' keys.
        let after = HeadingTree.build(Self.outline("## New\n\n## Ghost\n\n### 1987\n\n## Notes\n\n## Notes\n"))
        #expect(Set(Self.shape(before)).isSubset(of: Set(Self.shape(after))))
        // Slashes in titles don't fake nesting.
        #expect(HeadingTree.build(Self.outline("## Act one/two\n")).first?.key == "Act one∕two")
    }

    @Test func rowsSkipClosedBranches() {
        let tree = HeadingTree.build(Self.outline("## A\n\n### A1\n\n#### A1a\n\n## B\n\n### B1\n"))
        #expect(HeadingTree.rows(tree, isOpen: { _ in false }).map(\.node.key) == ["A", "B"])
        let open: Set<String> = ["A", "A/A1"]
        let rows = HeadingTree.rows(tree, isOpen: { open.contains($0) })
        #expect(rows.map(\.node.key) == ["A", "A/A1", "A/A1/A1a", "B"])
        #expect(rows.map(\.depth) == [0, 1, 2, 0])
        #expect(HeadingTree.keys(tree).count == 5)
    }
}
