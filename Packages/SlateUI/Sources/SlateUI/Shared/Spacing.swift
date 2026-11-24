import CoreGraphics

/// Padding shared across areas, so boards and lists sit the same distance
/// from their edges everywhere.
enum Spacing {
    /// Filter bars, footers and other panel rows.
    static let panel: CGFloat = 12
    /// Horizontal inset of a board's content (storyboard rows, note editor margins).
    static let content: CGFloat = 16
    /// Space above and below a board's content.
    static let contentVertical: CGFloat = 12
    /// Between a row's heading and its content.
    static let row: CGFloat = 8
}
