import AppKit
import SlateCore
import SwiftUI

/// The sidebar's Spelling tab: every misspelled word in the open file, with
/// how often it appears, a line of context, suggestions and the
/// dictionary's learn / ignore actions. Uses the editors' spell-document tag
/// and ignore list, so the tab and the red underlines always agree.
@MainActor
@Observable
final class SpellingPanelModel {
    /// The file last scanned.
    private(set) var path: String?
    private(set) var issues: [Misspelling] = []
    /// Spelling is switched off for this file's area (Settings › Spelling).
    private(set) var checkingOff = false
    var error: String?
    /// The text `issues` were found in, so a replace can tell if it changed.
    @ObservationIgnored private(set) var scannedText: String?
    /// The next occurrence to show, per word (click again for the next one).
    @ObservationIgnored private var cursors: [String: Int] = [:]
    /// The occurrence last shown, per word: what a suggestion replaces.
    @ObservationIgnored private var shown: [String: NSRange] = [:]

    static let debounce: Duration = .milliseconds(500)

    var count: Int { issues.count }

    /// Re-checks `path` (nil: nothing open). Called after typing pauses, on
    /// file switch, and when the dictionary or ignore list changes.
    func scan(path: String?, session: ProjectSession) {
        if path != self.path {
            cursors = [:]
            shown = [:]
        }
        self.path = path
        guard let path, let text = try? session.store.readText(at: path) else {
            issues = []
            scannedText = nil
            checkingOff = false
            return
        }
        let kind = SpellingScan.kind(for: path, text: text)
        let dictionary = session.dictionary
        let spelling = dictionary.spelling(for: kind == .script ? .script : .notes, characters: session.script.characterNames)
        checkingOff = !spelling.checking
        guard spelling.checking, let tag = spelling.documentTag else {
            issues = []
            scannedText = text
            return
        }
        SpellingScan.applyIgnoredWords(spelling.ignoredWords, tag: tag)
        let found = SpellingScan.misspellings(in: text, kind: kind, tag: tag, language: spelling.language)
        if found != issues { issues = found }
        scannedText = text
        for (word, index) in cursors where found.first(where: { $0.word == word }).map({ index >= $0.count }) ?? true {
            cursors[word] = nil
        }
    }

    /// The next occurrence of `issue` to show (wrapping round), remembered as the one a suggestion replaces.
    func nextOccurrence(of issue: Misspelling) -> NSRange? {
        guard !issue.ranges.isEmpty else { return nil }
        let index = (cursors[issue.word] ?? 0) % issue.ranges.count
        cursors[issue.word] = index + 1
        shown[issue.word] = issue.ranges[index]
        return issue.ranges[index]
    }

    /// The occurrence a suggestion replaces: the one last shown, else the first.
    func currentOccurrence(of issue: Misspelling) -> NSRange? {
        if let range = shown[issue.word], issue.ranges.contains(range) { return range }
        return issue.ranges.first
    }

    /// Replaces one occurrence, or all of them, through the file's open document.
    func replace(_ issue: Misspelling, with replacement: String, all: Bool, session: ProjectSession) {
        guard let path else { return }
        error = nil
        do {
            let document = try session.store.document(at: path)
            let ns = document.text as NSString
            let ranges = all ? issue.ranges : currentOccurrence(of: issue).map { [$0] } ?? []
            guard document.text == scannedText || ranges.allSatisfy({ NSMaxRange($0) <= ns.length && ns.substring(with: $0) == issue.word }) else {
                error = "The text changed since it was checked. The list has been refreshed."
                scan(path: path, session: session)
                return
            }
            let updated = NSMutableString(string: document.text)
            for range in ranges.sorted(by: { $0.location > $1.location }) {
                updated.replaceCharacters(in: range, with: replacement)
            }
            document.text = updated as String
            cursors[issue.word] = nil
            shown[issue.word] = nil
            scan(path: path, session: session)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension ProjectSession {
    /// The text file the Spelling tab checks: the script's open act file, the
    /// open note, draft or text file in Universe, or `words.md` when the
    /// Dictionary shows it as text.
    var spellingPath: String? {
        switch area ?? .script {
        case .script:
            return script.showingTitlePage ? nil : script.currentFile
        case .universe:
            guard let path = universeSelection else { return nil }
            let lower = path.lowercased()
            if lower.hasSuffix(".canvas") || lower.hasSuffix(TimelineFile.suffix) || lower.hasSuffix(MapFile.suffix) { return nil }
            return ProjectLayout.isTextFile(path) ? path : nil
        case .dictionary:
            return showingWordBookSource ? WordBook.path : nil
        case .storyboard:
            return nil
        }
    }

    /// Spelling tab › a row: shows the next place the word appears.
    func revealNext(_ issue: Misspelling) {
        guard let path = spelling.path, let range = spelling.nextOccurrence(of: issue) else { return }
        open(path, range: range)
    }
}

/// Keeps the Spelling tab's list (and the tab's count) current: re-checks
/// half a second after typing stops, and at once on a file switch or a
/// dictionary change.
struct SpellingScanner: ViewModifier {
    let session: ProjectSession

    private struct Key: Equatable {
        var path: String?
        var text: String?
        var version: Int
        var ignored: Int
        var settings: SpellingSettings
    }

    func body(content: Content) -> some View {
        let path = session.spellingPath
        let key = Key(path: path, text: path.flatMap { try? session.store.readText(at: $0) },
                      version: session.dictionary.version, ignored: session.dictionary.ignoredThisSession.count,
                      settings: session.dictionary.settings)
        content.task(id: key) {
            // Only typing waits; a new file or dictionary change shows at once.
            if key.path == session.spelling.path, key.text != session.spelling.scannedText {
                try? await Task.sleep(for: SpellingPanelModel.debounce)
                if Task.isCancelled { return }
            }
            session.spelling.scan(path: key.path, session: session)
        }
    }
}

struct SpellingPanel: View {
    let session: ProjectSession

    var body: some View {
        let model = session.spelling
        VStack(spacing: 0) {
            PanelFilterBar {
                Text(model.path.map { ($0 as NSString).lastPathComponent } ?? "No file open")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            } trailing: {
                if model.count > 0 {
                    Text(model.count == 1 ? "1 word" : "\(model.count) words").foregroundStyle(.secondary)
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, Spacing.panel)
            }
            List(model.issues) { issue in
                SpellingRow(session: session, issue: issue)
            }
            .listStyle(.plain)
            .overlay {
                if model.issues.isEmpty {
                    if model.path == nil {
                        ContentUnavailableView("No File Open", systemImage: "textformat.abc",
                                               description: Text("Open a scene, note or the draft to check its spelling."))
                    } else if model.checkingOff {
                        ContentUnavailableView("Spell Checking Is Off", systemImage: "textformat.abc",
                                               description: Text("Turn it on in Settings › Spelling."))
                    } else {
                        ContentUnavailableView("No Spelling Issues", systemImage: "checkmark.circle",
                                               description: Text("Words in the dictionary, character names and screenplay terms are never flagged."))
                    }
                }
            }
        }
    }
}

private struct SpellingRow: View {
    let session: ProjectSession
    let issue: Misspelling

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(issue.word).font(.body.weight(.semibold)).foregroundStyle(.red)
                if issue.count > 1 {
                    Text("\(issue.count)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .help("Appears \(issue.count) times. Click again to go to the next one.")
                }
                Spacer(minLength: 4)
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Suggestions, learn, ignore")
            }
            Text(highlighted)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture { session.revealNext(issue) }
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the word in the editor")
    }

    @ViewBuilder private var actions: some View {
        if issue.guesses.isEmpty {
            Text("No Suggestions")
        } else {
            Section("Replace (⌥-click: all \(issue.count))") {
                ForEach(issue.guesses, id: \.self) { guess in
                    Button(guess) {
                        let all = NSEvent.modifierFlags.contains(.option)
                        session.spelling.replace(issue, with: guess, all: all, session: session)
                    }
                }
            }
        }
        Divider()
        Button("Learn for This Project") { session.dictionary.learn(issue.word, global: false) }
        Button("Learn Everywhere") { session.dictionary.learn(issue.word, global: true) }
        Button("Ignore") { session.dictionary.ignore(issue.word) }
        Button("Add as Term…") { session.sheet = .wordEntry(nil, word: issue.word) }
    }

    private var highlighted: AttributedString {
        let ns = issue.context as NSString
        let range = NSIntersectionRange(issue.contextRange, NSRange(location: 0, length: ns.length))
        var text = AttributedString(ns.substring(to: range.location))
        var hit = AttributedString(ns.substring(with: range))
        hit.inlinePresentationIntent = .stronglyEmphasized
        hit.foregroundColor = .primary
        text += hit
        text += AttributedString(ns.substring(from: NSMaxRange(range)))
        return text
    }
}
