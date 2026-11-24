import AppKit
import SlateCore
import SwiftUI

/// Settings › Spelling (UserDefaults keys and defaults).
enum SpellingPreferences {
    /// An `NSSpellChecker` language code, or empty for Automatic.
    static let language = "spellingLanguage"
    static let grammarInScript = "grammarInScript"
    static let grammarInNotes = "grammarInNotes"
    static let autocorrect = "spellingAutocorrect"

    /// `spelling.<area>` and `grammar.<area>` for the areas without older keys.
    static func checkKey(_ area: EditorSpelling.Area) -> String { "spelling." + area.rawValue }
    static func grammarKey(_ area: EditorSpelling.Area) -> String {
        switch area {
        case .script: grammarInScript
        case .notes: grammarInNotes
        default: "grammar." + area.rawValue
        }
    }

    /// Spelling is on everywhere but canvas cards; grammar only in notes.
    static func defaultCheck(_ area: EditorSpelling.Area) -> Bool { area != .cards }
    static func defaultGrammar(_ area: EditorSpelling.Area) -> Bool { area == .notes }

    static var current: SpellingSettings {
        let defaults = UserDefaults.standard
        var check: [EditorSpelling.Area: Bool] = [:], grammar: [EditorSpelling.Area: Bool] = [:]
        for area in EditorSpelling.Area.allCases {
            check[area] = defaults.object(forKey: checkKey(area)) as? Bool ?? defaultCheck(area)
            grammar[area] = defaults.object(forKey: grammarKey(area)) as? Bool ?? defaultGrammar(area)
        }
        return SpellingSettings(
            language: defaults.string(forKey: language) ?? "",
            check: check,
            grammar: grammar,
            autocorrect: defaults.object(forKey: autocorrect) as? Bool ?? false
        )
    }
}

struct SpellingSettings: Equatable {
    var language: String
    /// Check as you type, per area.
    var check: [EditorSpelling.Area: Bool]
    var grammar: [EditorSpelling.Area: Bool]
    var autocorrect: Bool
}

/// What an editor needs from the dictionary: words not to flag, defined
/// words to underline, and the spelling settings for its area.
struct EditorSpelling: Equatable {
    enum Area: String, CaseIterable, Identifiable {
        case script, notes, cards, margin
        var id: String { rawValue }
        var title: String {
            switch self {
            case .script: "Script"
            case .notes: "Notes, draft and dictionary"
            case .cards: "Canvas cards"
            case .margin: "Margin to-dos and notes"
            }
        }
    }

    var ignoredWords: [String]
    var matcher: TermMatcher
    /// Bumped when the books change, so the matcher needn't be compared.
    var matcherVersion: Int
    var grammar: Bool
    var autocorrect: Bool
    var language: String
    /// Check spelling as you type.
    var checking = true
    /// The project's spell-document tag, shared by its script and Markdown
    /// editors and the sidebar's Spelling tab. Nil: the text view's own.
    var documentTag: Int?

    static let none = EditorSpelling(ignoredWords: [], matcher: .empty, matcherVersion: -1, grammar: false, autocorrect: false, language: "")

    static func == (a: EditorSpelling, b: EditorSpelling) -> Bool {
        a.matcherVersion == b.matcherVersion && a.grammar == b.grammar && a.autocorrect == b.autocorrect && a.checking == b.checking
            && a.language == b.language && a.ignoredWords == b.ignoredWords && a.documentTag == b.documentTag
    }
}

/// Shared by the editors: applies `EditorSpelling` to a text view, draws
/// the dotted underline under defined words (TextKit 2 rendering
/// attributes, so the text and undo are untouched) and answers which word
/// sits under the pointer.
@MainActor
final class TermDecorator {
    private weak var textView: NSTextView?
    private var spelling = EditorSpelling.none
    private var appliedWords: [String]?
    private var color = NSColor.systemPurple
    private(set) var hits: [TermMatcher.Hit] = []
    private var work: DispatchWorkItem?
    /// Extra ranges to skip (code spans, scene markers), from the editor.
    var protectedRanges: () -> [NSRange] = { [] }

    init(textView: NSTextView) {
        self.textView = textView
    }

    /// Applies spelling settings and, when the books changed, re-marks terms.
    func apply(_ spelling: EditorSpelling, color: NSColor) {
        guard let textView else { return }
        let old = self.spelling
        self.spelling = spelling
        if let slate = textView as? SlateTextView, slate.sharedSpellTag != spelling.documentTag {
            slate.sharedSpellTag = spelling.documentTag
            appliedWords = nil
        }
        if appliedWords != spelling.ignoredWords {
            appliedWords = spelling.ignoredWords
            NSSpellChecker.shared.setIgnoredWords(spelling.ignoredWords, inSpellDocumentWithTag: textView.spellCheckerDocumentTag)
            // Re-check what's on screen with the new list.
            if textView.isContinuousSpellCheckingEnabled {
                textView.isContinuousSpellCheckingEnabled = false
                textView.isContinuousSpellCheckingEnabled = true
            }
        }
        if textView.isContinuousSpellCheckingEnabled != spelling.checking { textView.isContinuousSpellCheckingEnabled = spelling.checking }
        if textView.isGrammarCheckingEnabled != spelling.grammar { textView.isGrammarCheckingEnabled = spelling.grammar }
        if textView.isAutomaticSpellingCorrectionEnabled != spelling.autocorrect {
            textView.isAutomaticSpellingCorrectionEnabled = spelling.autocorrect
        }
        if old.language != spelling.language || appliedWords == nil {
            let checker = NSSpellChecker.shared
            if spelling.language.isEmpty {
                if !checker.automaticallyIdentifiesLanguages { checker.automaticallyIdentifiesLanguages = true }
            } else if checker.automaticallyIdentifiesLanguages || checker.language() != spelling.language {
                checker.automaticallyIdentifiesLanguages = false
                checker.setLanguage(spelling.language)
            }
        }
        let colorChanged = color != self.color
        self.color = color
        if old.matcherVersion != spelling.matcherVersion || colorChanged { refresh() }
    }

    /// Call after every edit: re-marks shortly after typing pauses.
    func textChanged() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func refresh() {
        work?.cancel()
        work = nil
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
        let text = textView.string
        let found = spelling.matcher.isEmpty ? [] : spelling.matcher.matches(
            in: text, excluding: TermMatcher.protectedRanges(in: text) + protectedRanges()
        )
        layout.removeRenderingAttribute(.underlineStyle, for: layout.documentRange)
        layout.removeRenderingAttribute(.underlineColor, for: layout.documentRange)
        let style = NSUnderlineStyle.single.union(.patternDot).rawValue
        for hit in found {
            guard let start = content.location(content.documentRange.location, offsetBy: hit.range.location),
                  let end = content.location(start, offsetBy: hit.range.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            layout.addRenderingAttribute(.underlineStyle, value: style, for: range)
            layout.addRenderingAttribute(.underlineColor, value: color, for: range)
        }
        hits = found
    }

    /// The defined word at a character index, if any.
    func hit(at index: Int) -> TermMatcher.Hit? {
        hits.first { NSLocationInRange(index, $0.range) }
    }
}
