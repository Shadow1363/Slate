import SlateCore
import SwiftUI

// MARK: - Navigator: the index

/// The Dictionary area's middle column: search, the A–Z index and every
/// word in the project book (and the global one, underneath).
struct DictionaryNavigator: View {
    @Bindable var session: ProjectSession

    var body: some View {
        let dictionary = session.dictionary
        let project = WordBook.search(session.dictionaryQuery, in: dictionary.entries)
        let global = WordBook.search(session.dictionaryQuery, in: dictionary.globalEntries)
        let searching = !session.dictionaryQuery.trimmingCharacters(in: .whitespaces).isEmpty
        let letters = Self.letters(in: project)
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                List(selection: $session.dictionarySelection) {
                    if searching {
                        Section("\(project.count + global.count) Results") {
                            ForEach(project) { row($0, global: false) }
                            ForEach(global) { row($0, global: true) }
                        }
                    } else {
                        ForEach(letters, id: \.self) { letter in
                            Section(letter) {
                                ForEach(project.filter { WordBook.letter(for: $0.word) == letter }) { row($0, global: false) }
                            }
                            .id(letter)
                        }
                        if !global.isEmpty {
                            Section("Every Project") {
                                ForEach(global) { row($0, global: true) }
                            }
                        }
                    }
                }
                .overlay {
                    if project.isEmpty, global.isEmpty {
                        if searching {
                            ContentUnavailableView.search(text: session.dictionaryQuery)
                        } else {
                            ContentUnavailableView {
                                Label("No Words Yet", systemImage: "character.book.closed")
                            } description: {
                                Text("Add made-up words, names and their meanings. Right-click a misspelling in any editor to add it.")
                            }
                        }
                    }
                }
                if !searching {
                    LetterRail(available: Set(letters)) { letter in
                        withAnimation { proxy.scrollTo(letter, anchor: .top) }
                    }
                }
            }
        }
        .searchable(text: $session.dictionaryQuery, placement: .sidebar, prompt: "Search words and meanings")
        .navigationTitle("Dictionary")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    session.sheet = .wordEntry(nil, word: session.dictionaryQuery)
                } label: {
                    Label("Add Word", systemImage: "plus")
                }
                .help("Add a word (⌘N)")
                Toggle(isOn: $session.showingWordBookSource) {
                    Label("Edit words.md", systemImage: "doc.plaintext")
                }
                .help("Show the word book as text")
            }
        }
        .onChange(of: session.dictionarySelection) { _, selection in
            if selection != nil { session.showingWordBookSource = false }
        }
    }

    private func row(_ entry: WordEntry, global: Bool) -> some View {
        WordRow(entry: entry)
            .tag(DictionarySelection(entry, isGlobal: global))
            .contextMenu {
                Button("Edit…") { session.sheet = .wordEntry(entry, word: entry.word) }
                Button("Find Uses in Project") {
                    session.showSearch("!text \"\(entry.word)\"")
                }
                Divider()
                Button("Delete", role: .destructive) { session.dictionary.delete(entry) }
            }
    }

    static func letters(in entries: [WordEntry]) -> [String] {
        var seen: [String] = []
        for entry in WordBook.sorted(entries) {
            let letter = WordBook.letter(for: entry.word)
            if seen.last != letter { seen.append(letter) }
        }
        return seen
    }
}

private struct WordRow: View {
    let entry: WordEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.word).fontWeight(entry.isSpellingOnly ? .regular : .semibold)
                if let part = entry.part { Text(part).italic().foregroundStyle(.secondary) }
                if !entry.links.isEmpty { Image(systemName: "link").font(.caption2).foregroundStyle(.secondary) }
            }
            if !entry.isSpellingOnly, !entry.explanation.isEmpty {
                Text(entry.plainExplanation.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A–Z down the side, like the thumb index of a printed dictionary.
private struct LetterRail: View {
    let available: Set<String>
    let jump: (String) -> Void
    static let all = (65...90).map { String(UnicodeScalar($0)!) } + ["#"]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.all, id: \.self) { letter in
                Button(letter) { jump(letter) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(available.contains(letter) ? Color.accentColor : Color.secondary.opacity(0.4))
                    .disabled(!available.contains(letter))
                    .frame(width: 18)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("Jump to \(letter)")
            }
        }
        .padding(.vertical, 6)
        .frame(maxHeight: 520)
    }
}

// MARK: - Detail: the page

struct DictionaryDetail: View {
    @Bindable var session: ProjectSession
    @Environment(\.slateTheme) private var theme

    var body: some View {
        let dictionary = session.dictionary
        Group {
            if session.showingWordBookSource {
                WordBookSource(session: session)
            } else if let selection = session.dictionarySelection,
                      let entry = (selection.isGlobal ? dictionary.globalEntries : dictionary.entries).first(where: selection.matches) {
                WordPage(session: session, entry: entry, isGlobal: selection.isGlobal)
                    .id(selection)
            } else {
                BookPages(session: session)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = dictionary.error {
                Banner(systemImage: "exclamationmark.triangle.fill", message: error) { Button("Dismiss") { dictionary.error = nil } }
            }
        }
    }
}

/// Every defined word, as reading pages.
private struct BookPages: View {
    let session: ProjectSession

    var body: some View {
        let entries = WordBook.sorted(session.dictionary.entries)
        let defined = entries.filter { !$0.isSpellingOnly }
        let spellings = entries.filter(\.isSpellingOnly)
        if entries.isEmpty {
            ContentUnavailableView {
                Label("Dictionary", systemImage: "character.book.closed")
            } description: {
                Text("Your film's own words: made-up names, places, tech and slang. Each one can have a short meaning or link to a Universe note, and spell check accepts them everywhere.")
            } actions: {
                Button("Add Word") { session.sheet = .wordEntry(nil, word: "") }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(DictionaryNavigator.letters(in: defined), id: \.self) { letter in
                        Text(letter).font(.largeTitle.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(defined.filter { WordBook.letter(for: $0.word) == letter }) { entry in
                            WordCard(entry: entry, isGlobal: false)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { session.sheet = .wordEntry(entry, word: entry.word) }
                                .onTapGesture { session.dictionarySelection = DictionarySelection(entry, isGlobal: false) }
                        }
                    }
                    if !spellings.isEmpty {
                        Divider()
                        Text("Spellings").font(.headline)
                        Text(spellings.map(\.word).joined(separator: " · "))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(28)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .environment(\.openURL, linkAction(session))
        }
    }
}

/// One word in reading form: headword, part of speech, forms, meaning.
struct WordCard: View {
    let entry: WordEntry
    let isGlobal: Bool
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.word).font(large ? .largeTitle.weight(.bold) : .title3.weight(.semibold))
                if let part = entry.part { Text(part).italic().foregroundStyle(.secondary) }
                Spacer()
                if isGlobal {
                    Text("Every project").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !entry.forms.isEmpty {
                Text(entry.forms.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
            }
            if entry.isSpellingOnly {
                Text("A correct spelling, with no meaning written yet.").foregroundStyle(.secondary)
            } else if !entry.explanation.isEmpty {
                Text(LinkURL.attributed(entry.explanation))
                    .font(large ? .title3 : .body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

@MainActor
func linkAction(_ session: ProjectSession) -> OpenURLAction {
    OpenURLAction { url in
        guard let target = LinkURL.target(from: url) else { return .systemAction }
        session.followLink(target)
        return .handled
    }
}

/// One word's page: the card, then where it's used.
private struct WordPage: View {
    let session: ProjectSession
    let entry: WordEntry
    let isGlobal: Bool
    @State private var uses: [ProjectSearch.FileResult]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WordCard(entry: entry, isGlobal: isGlobal, large: true)
                HStack {
                    Button("Edit…") { session.sheet = .wordEntry(entry, word: entry.word) }
                    if let target = entry.links.first?.target, session.links.graph.resolve(target) != nil {
                        Button("Open \(target)") { session.followLink(target) }
                    }
                    Button("Look Up in Dictionary") { SystemDictionary.lookUp(entry.word) }
                }
                Divider()
                Text("Used In").font(.headline)
                if let uses {
                    if uses.isEmpty {
                        Text("Not used in the script or notes yet.").foregroundStyle(.secondary)
                    }
                    ForEach(uses) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(for: file.path)).font(.subheadline.weight(.semibold))
                            ForEach(file.matches) { match in
                                Button {
                                    session.open(match.path, location: match.range.location)
                                } label: {
                                    Text(highlighted(match))
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .environment(\.openURL, linkAction(session))
        .navigationTitle(entry.word)
        .task(id: entry) { uses = await findUses() }
    }

    private func findUses() async -> [ProjectSearch.FileResult] {
        let store = session.store
        let root = store.rootURL
        let paths = session.allPaths.filter(ProjectSearch.isSearchable)
        var overrides: [String: String] = [:]
        for (path, document) in store.documents { overrides[path] = document.text }
        let entry = entry
        return await Task.detached {
            let texts: [(path: String, text: String)] = paths.compactMap { path in
                if let text = overrides[path] { return (path, text) }
                guard let data = try? Data(contentsOf: root.appending(path: path)) else { return nil }
                return String(data: data, encoding: .utf8).map { (path, $0) }
            }
            return TermUsage.uses(of: entry, in: texts)
        }.value
    }

    private func title(for path: String) -> String {
        if let note = session.links.graph.note(at: path) { return note.name }
        if path.hasPrefix("script/") { return "Script · " + (path as NSString).lastPathComponent }
        return path
    }

    private func highlighted(_ match: ProjectSearch.Match) -> AttributedString {
        var text = AttributedString(match.snippet)
        if let range = Range(match.snippetRange, in: match.snippet),
           let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text) {
            text[lower..<upper].font = .body.bold()
        }
        return text
    }
}

/// `words.md` as text, in the Markdown editor.
private struct WordBookSource: View {
    let session: ProjectSession
    @Environment(\.slateTheme) private var theme

    var body: some View {
        if let document = try? session.store.document(at: WordBook.path) {
            VStack(spacing: 0) {
                DiskStateBanners(store: session.store, document: document, close: { session.showingWordBookSource = false })
                MarkdownEditor(document: document, text: document.text, hidesFrontmatter: false, theme: theme,
                               reveal: session.noteReveal, linkVersion: session.links.version, session: session,
                               spelling: session.noteSpelling)
                Divider()
                FileStatusBar(document: document)
            }
            .navigationTitle("words.md")
        } else {
            ContentUnavailableView {
                Label("No Word Book", systemImage: "doc.plaintext")
            } description: {
                Text("dictionary/words.md doesn't exist yet. Adding a word creates it.")
            } actions: {
                Button("Add Word") { session.sheet = .wordEntry(nil, word: "") }
            }
        }
    }
}

// MARK: - Entry sheet

/// Add or edit one word.
struct WordEntrySheet: View {
    let session: ProjectSession
    let editing: WordEntry?
    @State private var word: String
    @State private var part: String
    @State private var forms: String
    @State private var explanation: String
    @State private var global: Bool
    @State private var linkPicker = false
    @Environment(\.dismiss) private var dismiss

    init(session: ProjectSession, editing: WordEntry?, word: String) {
        self.session = session
        self.editing = editing
        _word = State(initialValue: editing?.word ?? word)
        _part = State(initialValue: editing?.part ?? "")
        _forms = State(initialValue: editing?.forms.joined(separator: ", ") ?? "")
        _explanation = State(initialValue: editing?.explanation ?? "")
        _global = State(initialValue: editing.map { session.dictionary.isGlobal($0) } ?? false)
    }

    var body: some View {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = global ? session.dictionary.globalEntries : session.dictionary.entries
        let duplicate = editing == nil ? WordBook.entry(for: trimmed, in: book) : nil
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "Add Word" : "Edit Word").font(.headline)
            Form {
                TextField("Word", text: $word, prompt: Text("Chronoshift"))
                TextField("Part of speech", text: $part, prompt: Text("noun, verb… (optional)"))
                TextField("Other forms", text: $forms, prompt: Text("chronoshifts, chronoshifted (optional)"))
                LabeledContent("Meaning") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $explanation)
                            .font(.body)
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.background, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                        HStack {
                            Text("Leave empty for a spelling only. [[Links]] point to Universe notes.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu("Link to Note") {
                                ForEach(session.links.graph.notes) { note in
                                    Button(note.name) {
                                        let link = WikiLink.text(for: note.name)
                                        explanation += explanation.isEmpty || explanation.hasSuffix(" ") ? link : " " + link
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
                if editing == nil {
                    Picker("Add to", selection: $global) {
                        Text("This project (dictionary/words.md)").tag(false)
                        Text("Every project").tag(true)
                    }
                }
            }
            if let duplicate {
                Text("“\(duplicate.word)” is already in this book.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if let editing {
                    Button("Delete", role: .destructive) {
                        session.dictionary.delete(editing)
                        session.dictionarySelection = nil
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || duplicate != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func save() {
        let entry = WordEntry(
            word: word.trimmingCharacters(in: .whitespacesAndNewlines),
            part: part.trimmingCharacters(in: .whitespaces).isEmpty ? nil : part.trimmingCharacters(in: .whitespaces),
            forms: forms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let editing {
            session.dictionary.update(editing, to: entry)
        } else {
            session.dictionary.add(entry, global: global)
        }
        if session.area == .dictionary {
            session.dictionarySelection = DictionarySelection(entry, isGlobal: editing.map { session.dictionary.isGlobal($0) } ?? global)
        }
        dismiss()
    }
}

// MARK: - Define panel

/// Inspector › Define: the selected word in the project dictionary, then
/// in macOS's dictionaries.
struct DefineInspector: View {
    let session: ProjectSession

    var body: some View {
        let word = currentWord
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let word {
                    if let entry = session.dictionary.entry(for: word), !entry.isSpellingOnly {
                        Text("In this film").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        WordCard(entry: entry, isGlobal: session.dictionary.isGlobal(entry))
                        Button("Show in Dictionary") { session.showInDictionary(entry) }
                        Divider()
                    }
                    Text("Dictionary").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let definition = SystemDictionary.definition(of: word) {
                        Text(definition).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No definition for “\(word)” in your Mac's dictionaries.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Look Up in Dictionary") { SystemDictionary.lookUp(word) }
                        if session.dictionary.entry(for: word) == nil {
                            Button("Define in Project…") { session.sheet = .wordEntry(nil, word: word) }
                        }
                    }
                } else {
                    Text("Select a word in the script or a note to see what it means.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openURL, linkAction(session))
    }

    private var currentWord: String? {
        let text = session.area == .script ? session.script.caret?.selection : session.selectedText
        guard let text, text.count <= 60 else { return nil }
        return text
    }
}
