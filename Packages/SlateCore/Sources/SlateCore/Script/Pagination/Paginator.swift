import Foundation

public enum LineAlignment: Sendable, Equatable {
    /// `x` is the left edge.
    case left
    /// `x` is the right edge.
    case right
    /// `x` is the centre.
    case center
}

/// One printed line on a page.
public struct PrintedLine: Sendable, Equatable {
    public var runs: [PrintedRun]
    /// Inches from the left edge of the page; see `alignment`.
    public var x: Double
    public var alignment: LineAlignment
    public var kind: ScriptElementKind
    /// Set on the first line of a scene heading when scene numbers are on.
    public var sceneNumber: String?

    public var text: String { runs.map(\.text).joined() }
}

public struct PrintedRow: Sendable, Equatable {
    /// 0-based line on the page, below the top margin.
    public var row: Int
    public var line: PrintedLine
}

/// Where a printed element came from: which act file, which line.
public struct SourceRef: Sendable, Equatable, Hashable {
    public var file: Int
    public var line: Int

    public init(file: Int, line: Int) {
        self.file = file
        self.line = line
    }
}

public struct PrintedPage: Sendable, Equatable {
    /// 1-based script page number (the title page isn't counted).
    public var number: Int
    public var rows: [PrintedRow]
    /// The first script line placed on this page.
    public var firstSource: SourceRef?
    /// The last script line placed on this page.
    public var lastSource: SourceRef?
}

public struct PaginatedScript: Sendable, Equatable {
    public let pages: [PrintedPage]
    /// Eighths of a page per scene, in script order.
    public let sceneEighths: [Int]
    public let format: ScreenplayFormat
    public var pageCount: Int { pages.count }

    /// The page showing a script line, for Page view.
    public func pageIndex(for source: SourceRef) -> Int? {
        pages.lastIndex { page in
            guard let first = page.firstSource else { return false }
            return (first.file, first.line) <= (source.file, source.line)
        }
    }
}

/// Lays a screenplay out on pages using the industry rules.
///
/// Spacing comes from the elements (as in Final Draft), not from the blank
/// lines in the file. Break rules:
/// - a scene heading never ends a page: it moves with at least two lines of
///   what follows;
/// - a speech splits only after a dialogue line that ends a sentence, with at
///   least two lines on each side, adding (MORE) and CHARACTER (CONT'D);
///   a character cue or parenthetical is never left at the bottom;
/// - action splits only at a sentence end or line end, two lines each side;
/// - `===` forces a new page.
public struct Paginator: Sendable {
    public var format: ScreenplayFormat
    public var settings: PublishSettings

    public init(format: ScreenplayFormat? = nil, settings: PublishSettings = PublishSettings()) {
        self.settings = settings
        self.format = format ?? ScreenplayFormat(pageSize: settings.pageSize)
    }

    // MARK: - Blocks

    struct Row {
        var lines: [PrintedLine]
        var kind: ScriptElementKind
        /// A page may break after this row (sentence end or end of a source line).
        var breakable: Bool
    }

    struct Block {
        enum Kind { case heading, action, speech, dual, transition, centered, forcedBreak }
        var kind: Kind
        var rows: [Row]
        var scene: Int?
        var source: SourceRef
        var cue: String = ""
        var items: [(kind: ScriptElementKind, runs: [PrintedRun])] = []
    }

    public func paginate(_ files: [ParsedScript]) -> PaginatedScript {
        let blocks = makeBlocks(files)
        return place(blocks, sceneCount: blocks.filter { $0.kind == .heading }.count)
    }

    func makeBlocks(_ files: [ParsedScript]) -> [Block] {
        var blocks: [Block] = []
        var scene: Int?
        var sceneCount = 0
        var lastSpeaker: String?

        for (fileIndex, parsed) in files.enumerated() {
            let lines = parsed.lines
            var i = 0
            while i < lines.count {
                let line = lines[i]
                let source = SourceRef(file: fileIndex, line: i)
                switch line.kind {
                case .blank, .boneyard, .synopsis:
                    i += 1

                case .pageBreak:
                    blocks.append(Block(kind: .forcedBreak, rows: [], scene: scene, source: source))
                    i += 1

                case .sceneHeading:
                    scene = sceneCount
                    sceneCount += 1
                    lastSpeaker = nil
                    let number = settings.sceneNumbers ? String(sceneCount) : nil
                    var rows = wrapped(runs(for: line), width: format.heading.width, x: format.heading.x, kind: .sceneHeading)
                    if !rows.isEmpty { rows[0].lines[0].sceneNumber = number }
                    blocks.append(Block(kind: .heading, rows: rows, scene: scene, source: source))
                    i += 1

                case .action, .lyric, .parenthetical, .dialogue:
                    // A paragraph: consecutive non-blank action lines. (Stray
                    // dialogue without a cue prints as action.)
                    var rows: [Row] = []
                    while i < lines.count, [.action, .lyric, .parenthetical, .dialogue].contains(lines[i].kind) {
                        var lineRuns = runs(for: lines[i])
                        if lines[i].kind == .lyric { lineRuns = lineRuns.map { var r = $0; r.italic = true; return r } }
                        rows += wrapped(lineRuns, width: format.action.width, x: format.action.x, kind: .action)
                        i += 1
                    }
                    blocks.append(Block(kind: .action, rows: rows, scene: scene, source: source))

                case .centered:
                    var rows: [Row] = []
                    while i < lines.count, lines[i].kind == .centered {
                        var text = ScriptEstimate.printedText(of: lines[i])
                        if text.hasSuffix("<") { text.removeLast() }
                        let lineRuns = Emphasis.runs(in: Emphasis.printable(text.trimmingCharacters(in: .whitespaces)), enabled: settings.emphasis)
                        for wrappedRuns in LineWrapper.wrap(lineRuns, width: format.action.width) {
                            rows.append(Row(lines: [PrintedLine(runs: wrappedRuns, x: format.centerLine, alignment: .center, kind: .centered)], kind: .centered, breakable: true))
                        }
                        i += 1
                    }
                    blocks.append(Block(kind: .centered, rows: rows, scene: scene, source: source))

                case .transition:
                    let text = ScriptEstimate.printedText(of: line)
                    let lineRuns = Emphasis.runs(in: Emphasis.printable(text), enabled: settings.emphasis)
                    let rows = LineWrapper.wrap(lineRuns, width: format.action.width).map {
                        Row(lines: [PrintedLine(runs: $0, x: format.transitionRightEdge, alignment: .right, kind: .transition)], kind: .transition, breakable: true)
                    }
                    blocks.append(Block(kind: .transition, rows: rows, scene: scene, source: source))
                    i += 1

                case .character:
                    var cue = ScriptEstimate.printedText(of: line)
                    let isDual = cue.hasSuffix("^")
                    if isDual { cue = String(cue.dropLast()).trimmingCharacters(in: .whitespaces) }
                    let name = ScriptParser.characterName(fromCue: cue)
                    if settings.autoContd, !isDual, let name, name == lastSpeaker, !cue.uppercased().contains("CONT'D") {
                        cue += " (CONT'D)"
                    }
                    lastSpeaker = name
                    i += 1
                    var items: [(kind: ScriptElementKind, runs: [PrintedRun])] = []
                    while i < lines.count, lines[i].kind == .parenthetical || lines[i].kind == .dialogue {
                        items.append((lines[i].kind, runs(for: lines[i])))
                        i += 1
                    }
                    var block = Block(kind: .speech, rows: [], scene: scene, source: source, cue: cue, items: items)
                    if isDual, let previous = blocks.last, previous.kind == .speech {
                        blocks.removeLast()
                        block.kind = .dual
                        block.source = previous.source
                        block.rows = dualRows(left: previous, right: block)
                    } else {
                        block.rows = speechRows(cue: cue, items: items, cueX: format.character.x, dialogue: format.dialogue, parenthetical: format.parenthetical)
                    }
                    blocks.append(block)
                }
            }
        }
        return blocks
    }

    private func runs(for line: ScriptLine) -> [PrintedRun] {
        Emphasis.runs(in: Emphasis.printable(ScriptEstimate.printedText(of: line)), enabled: settings.emphasis)
    }

    private func wrapped(_ runs: [PrintedRun], width: Int, x: Double, kind: ScriptElementKind) -> [Row] {
        let lines = LineWrapper.wrap(runs, width: width)
        return lines.enumerated().map { index, lineRuns in
            let text = lineRuns.map(\.text).joined()
            return Row(
                lines: [PrintedLine(runs: lineRuns, x: x, alignment: .left, kind: kind)],
                kind: kind,
                breakable: index == lines.count - 1 || Self.endsSentence(text)
            )
        }
    }

    static func endsSentence(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while let last = trimmed.last, "\"'”’)".contains(last) { trimmed.removeLast() }
        guard let last = trimmed.last else { return false }
        return ".?!:;".contains(last) || trimmed.hasSuffix("--")
    }

    private func speechRows(cue: String, items: [(kind: ScriptElementKind, runs: [PrintedRun])], cueX: Double,
                            dialogue: ScreenplayFormat.Element, parenthetical: ScreenplayFormat.Element) -> [Row] {
        var rows: [Row] = []
        for wrappedCue in LineWrapper.wrap(cue, width: format.character.width) {
            rows.append(Row(lines: [PrintedLine(runs: [PrintedRun(wrappedCue)], x: cueX, alignment: .left, kind: .character)], kind: .character, breakable: false))
        }
        for item in items {
            let element = item.kind == .parenthetical ? parenthetical : dialogue
            var itemRows = wrapped(item.runs, width: element.width, x: element.x, kind: item.kind)
            if item.kind == .parenthetical {
                for index in itemRows.indices { itemRows[index].breakable = false }
            }
            rows += itemRows
        }
        return rows
    }

    private func dualRows(left: Block, right: Block) -> [Row] {
        let width = format.dualWidth
        func column(_ block: Block, start: Double) -> [Row] {
            speechRows(
                cue: block.cue, items: block.items, cueX: start + 1.2,
                dialogue: .init(x: start, width: width),
                parenthetical: .init(x: start + 0.3, width: width - 4)
            )
        }
        let l = column(left, start: format.dualColumns.left)
        let r = column(right, start: format.dualColumns.right)
        return (0..<max(l.count, r.count)).map { index in
            let lines = (index < l.count ? l[index].lines : []) + (index < r.count ? r[index].lines : [])
            return Row(lines: lines, kind: .dialogue, breakable: false)
        }
    }

    // MARK: - Placing

    private func place(_ blocks: [Block], sceneCount: Int) -> PaginatedScript {
        let capacity = format.linesPerPage
        var pages: [PrintedPage] = []
        var page = PrintedPage(number: 1, rows: [])
        var y = 0
        var sceneRowsOnPage: [Int: Int] = [:]
        var eighths = Array(repeating: 0, count: sceneCount)

        func finishPage() {
            for (scene, rows) in sceneRowsOnPage where scene < eighths.count {
                eighths[scene] += max(1, Int((Double(rows) * 8 / Double(capacity)).rounded()))
            }
            sceneRowsOnPage = [:]
            pages.append(page)
            page = PrintedPage(number: pages.count + 1, rows: [])
            y = 0
        }

        func put(_ rows: [Row], gap: Int, block: Block) {
            if page.firstSource == nil { page.firstSource = block.source }
            page.lastSource = block.source
            y += gap
            for row in rows {
                for line in row.lines { page.rows.append(PrintedRow(row: y, line: line)) }
                y += 1
            }
            if let scene = block.scene { sceneRowsOnPage[scene, default: 0] += gap + rows.count }
        }

        var queue = blocks[...]
        while var block = queue.popFirst() {
            if block.kind == .forcedBreak {
                if y > 0 { finishPage() }
                continue
            }
            guard !block.rows.isEmpty else { continue }
            let gap = y == 0 ? 0 : (block.kind == .heading ? format.headingSpacing : 1)
            var keep = 0
            if block.kind == .heading, let next = queue.first, next.kind != .heading, next.kind != .forcedBreak, !next.rows.isEmpty {
                keep = 1 + min(next.rows.count, next.kind == .speech ? 3 : 2)
            }

            if y + gap + block.rows.count + keep <= capacity {
                put(block.rows, gap: gap, block: block)
                continue
            }
            let available = capacity - y - gap
            if keep == 0, let (first, rest) = split(block, available: available) {
                put(first, gap: gap, block: block)
                finishPage()
                block.rows = rest
                queue.insert(block, at: queue.startIndex)
                continue
            }
            if y > 0 {
                finishPage()
                queue.insert(block, at: queue.startIndex)
                continue
            }
            // Taller than a whole page and can't split by the rules: cut it.
            let cut = split(block, available: capacity) ?? (Array(block.rows.prefix(capacity)), Array(block.rows.dropFirst(capacity)))
            put(cut.0, gap: 0, block: block)
            if !cut.1.isEmpty {
                finishPage()
                block.rows = cut.1
                queue.insert(block, at: queue.startIndex)
            }
        }
        if !page.rows.isEmpty || pages.isEmpty { finishPage() }
        return PaginatedScript(pages: pages, sceneEighths: eighths, format: format)
    }

    /// Splits a block so the first part fits in `available` rows.
    private func split(_ block: Block, available: Int) -> ([Row], [Row])? {
        let rows = block.rows
        switch block.kind {
        case .action:
            guard rows.count >= 4, available >= 2 else { return nil }
            for k in stride(from: min(available, rows.count - 2), through: 2, by: -1) where rows[k - 1].breakable {
                return (Array(rows[..<k]), Array(rows[k...]))
            }
            return nil
        case .speech:
            let cueRows = rows.prefix { $0.kind == .character }.count
            // First part: cue + at least 2 lines + (MORE); rest: at least 2 lines.
            guard available >= cueRows + 3 else { return nil }
            for k in stride(from: min(available - 1, rows.count - 2), through: cueRows + 2, by: -1)
            where rows[k - 1].kind == .dialogue && rows[k - 1].breakable {
                let more = Row(lines: [PrintedLine(runs: [PrintedRun("(MORE)")], x: format.character.x, alignment: .left, kind: .character)], kind: .character, breakable: false)
                let cue = block.cue.uppercased().contains("CONT'D") ? block.cue : block.cue + " (CONT'D)"
                let contd = Row(lines: [PrintedLine(runs: [PrintedRun(cue)], x: format.character.x, alignment: .left, kind: .character)], kind: .character, breakable: false)
                return (Array(rows[..<k]) + [more], [contd] + Array(rows[k...]))
            }
            return nil
        default:
            return nil
        }
    }
}
