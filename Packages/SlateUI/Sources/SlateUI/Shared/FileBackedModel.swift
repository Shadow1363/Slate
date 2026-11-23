import AppKit
import Observation
import SlateCore

/// A value read from a text file (a timeline, a map) and edited in place.
/// Edits go through the file's `TextDocument`, written 0.3 s after the last
/// change, so autosave, outside reloads and conflict banners work as for any
/// file. Each edit is one undo step; a drag is one step from start to end.
@MainActor
@Observable
final class FileBackedModel<Value: TextBackedFile> {
    let document: TextDocument
    private(set) var value: Value
    private(set) var parseError: String?

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var syncedText: String
    @ObservationIgnored private var writeWork: DispatchWorkItem?
    @ObservationIgnored private var interactionStart: Value?
    /// Called after the value changes underneath (an outside edit), to tidy selections.
    @ObservationIgnored var onReload: ((Value) -> Void)?

    init(document: TextDocument, empty: Value) {
        self.document = document
        syncedText = document.text
        do {
            value = try Value(text: document.text)
        } catch {
            value = empty
            parseError = error.localizedDescription
        }
    }

    /// Call when the document's text may have changed underneath (a reload from disk).
    func documentChanged() {
        guard document.text != syncedText else { return }
        syncedText = document.text
        writeWork?.cancel()
        do {
            let fresh = try Value(text: document.text)
            parseError = nil
            if fresh != value {
                value = fresh
                onReload?(fresh)
            }
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func scheduleWrite() {
        writeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        writeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes pending edits to the document now. An unchanged value is never
    /// rewritten, so hand-formatted files keep their layout.
    func flush() {
        writeWork?.cancel()
        writeWork = nil
        guard parseError == nil else { return }
        if let current = try? Value(text: document.text), current == value { return }
        let text = value.text
        syncedText = text
        if document.text != text { document.text = text }
    }

    /// Replaces the value as one undoable step.
    func apply(_ new: Value, _ action: String) {
        guard new != value, parseError == nil else { return }
        let old = value
        value = new
        registerUndo(back: old, action)
        scheduleWrite()
    }

    func edit(_ action: String, _ change: (Value) -> Value) {
        apply(change(value), action)
    }

    private func registerUndo(back old: Value, _ action: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.apply(old, action) }
        }
        undoManager.setActionName(action)
    }

    /// A live change during a drag (no undo step yet).
    func update(_ new: Value) {
        guard parseError == nil else { return }
        if interactionStart == nil { interactionStart = value }
        value = new
    }

    func endInteraction(_ action: String) {
        guard let start = interactionStart else { return }
        interactionStart = nil
        guard start != value else { return }
        registerUndo(back: start, action)
        scheduleWrite()
    }
}
