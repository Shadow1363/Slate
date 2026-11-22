import Foundation
import Testing
@testable import SlateCore
@testable import SlateExport

/// Milestone 3's "done when": page breaks within two lines of the reference PDFs.
@Suite("Page breaks match the reference PDFs")
struct ReferenceTests {
    @Test func brickAndSteel() throws {
        let ours = try Samples.paginate("Brick-and-Steel.fountain", format: Samples.brickAndSteelFormat)
        let reference = ReferencePDF.lines(at: Fixtures.fountain.appending(path: "Brick-and-Steel.pdf"))
        let comparison = BreakComparison.compare(ours: ours, reference: reference)
        print("Brick & Steel:", comparison.report)
        #expect(comparison.pageCountOurs == comparison.pageCountReference)
        #expect(comparison.allFound)
        #expect(comparison.worst <= 2)
    }

    @Test func theLastBirthdayCard() throws {
        let ours = try Samples.paginate("The-Last-Birthday-Card.fountain", format: Samples.lastBirthdayCardFormat)
        let reference = ReferencePDF.lines(at: Fixtures.fountain.appending(path: "The-Last-Birthday-Card.pdf"))
        let comparison = BreakComparison.compare(ours: ours, reference: reference)
        print("Last Birthday Card:", comparison.report)
        #expect(comparison.pageCountOurs == comparison.pageCountReference)
        #expect(comparison.allFound)
        #expect(comparison.worst <= 2)
    }
}
