import AppKit

/// Showing where a jump lands (Search, backlinks, to-dos, spelling): every
/// editor selects the range, scrolls it to the middle of the view and
/// flashes it with the find indicator.
@MainActor
enum TextReveal {
    /// How long the scroll takes. Instant with Reduce Motion on.
    static let duration: TimeInterval = 0.25
    /// Tests set this to stand in for System Settings › Accessibility › Reduce Motion.
    static var reduceMotionOverride: Bool?

    static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension NSTextView {
    /// Selects `range`, scrolls it to the vertical centre and flashes it.
    /// - Parameter focus: give the editor the keyboard too.
    func reveal(range: NSRange, focus: Bool) {
        let length = (string as NSString).length
        let location = max(0, min(range.location, length))
        let selection = NSRange(location: location, length: max(0, min(range.length, length - location)))
        setSelectedRange(selection)
        if focus { window?.makeFirstResponder(self) }

        guard let clip = enclosingScrollView?.contentView, let rect = boundingRect(of: selection) else {
            scrollRangeToVisible(selection)
            flash(selection)
            return
        }
        let target = centredOrigin(for: convert(rect, to: clip), in: clip)
        guard target != clip.bounds.origin else {
            flash(selection)
            return
        }
        if TextReveal.reduceMotion || window == nil {
            clip.setBoundsOrigin(target)
            enclosingScrollView?.reflectScrolledClipView(clip)
            flash(selection)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TextReveal.duration
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.enclosingScrollView?.reflectScrolledClipView(clip)
                    self.flash(selection)
                }
            }
        }
    }

    /// The clip view origin that puts `rect` (in clip coordinates) in the middle, kept inside the document.
    func centredOrigin(for rect: CGRect, in clip: NSClipView) -> CGPoint {
        let visible = clip.bounds
        let document = clip.documentView?.frame ?? frame
        let maxY = max(document.minY, document.maxY - visible.height)
        let y = min(max(rect.midY - visible.height / 2, document.minY), maxY)
        return CGPoint(x: visible.origin.x, y: y.rounded())
    }

    /// Where `range` sits, in this view's coordinates (TextKit 2, else TextKit 1).
    func boundingRect(of range: NSRange) -> CGRect? {
        let origin = textContainerOrigin
        if let layout = textLayoutManager, let content = layout.textContentManager,
           let start = content.location(content.documentRange.location, offsetBy: range.location),
           let end = content.location(start, offsetBy: range.length),
           let textRange = NSTextRange(location: start, end: end) {
            layout.ensureLayout(for: textRange)
            var rect = CGRect.null
            layout.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                rect = rect.union(frame)
                return true
            }
            if rect.isNull, range.length == 0 {
                // A caret: the line fragment it's in.
                layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                    rect = fragment.layoutFragmentFrame
                    return false
                }
            }
            return rect.isNull ? nil : rect.offsetBy(dx: origin.x, dy: origin.y)
        }
        if let layout = layoutManager, let container = textContainer {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.ensureLayout(forGlyphRange: glyphs)
            return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
        }
        return nil
    }

    private func flash(_ range: NSRange) {
        guard range.length > 0, window != nil else { return }
        showFindIndicator(for: range)
    }
}
