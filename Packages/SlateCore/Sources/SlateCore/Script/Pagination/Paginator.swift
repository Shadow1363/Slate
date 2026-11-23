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
    /// The script line it prints.
    public var source: SourceRef? = nil
    /// The scene it belongs to (0-based, script order).
    public var scene: Int? = nil
    /// Changed in the current revision: printed with a `*` in the right margin.
    public var revised = false

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
    /// 1-based position among the script's pages (the title page isn't counted).
    public var number: Int
    public var rows: [PrintedRow]
    /// The first script line placed on this page.
    public var firstSource: SourceRef?
    /// The last script line placed on this page.
    public var lastSource: SourceRef?
    /// Where the page starts: the first line of the block it starts in, and how
    /// many of that block's printed lines came before (0 at a block's start).
    public var startSource: SourceRef? = nil
    public var startRow = 0
    /// The printed page number when it isn't `number` (locked pages: `23A`).
    public var pageLabel: String? = nil
    /// Set when the page has revision marks: its header shows this revision.
    public var revision: ScriptRevision? = nil
    /// A locked page whose content was cut.
    public var omitted = false

    public init(number: Int, rows: [PrintedRow], firstSource: SourceRef? = nil, lastSource: SourceRef? = nil) {
        self.number = number
        self.rows = rows
        self.firstSource = firstSource
        self.lastSource = lastSource
    }

    /// The number printed at the top: `12`, or `12A` for a locked script.
    public var label: String { pageLabel ?? String(number) }
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
    /// Locked numbers and pages, and revision marks.
    public var production: ProductionLayout?

    public init(format: ScreenplayFormat? = nil, settings: PublishSettings = PublishSettings(), production: ProductionLayout? = nil) {
        self.settings = settings
        self.format = format ?? ScreenplayFormat(pageSize: settings.pageSize)
        self.production = production
    }

    // MARK: - Blocks

    struct Row {
        var lines: [PrintedLine]
        var kind: ScriptElementKind
        /// A page may break after this row (sentence end or end of a source line).
        var breakable: Bool
    }

    struct Block {
        enum Kind { case heading, action, speech, dual, transition, centered, forcedBreak, omitted }
        var kind: Kind
        var rows: [Row]
        var scene: Int?
        var source: SourceRef
        var cue: String = ""
        var items: [(kind: ScriptElementKind, runs: [PrintedRun], line: Int)] = []
        /// Printed lines of the original block already placed on earlier pages.
        var consumed = 0
        /// 1 when `rows` starts with an added CHARACTER (CONT'D) line.
        var leadingExtra = 0
    }

    public func paginate(_ files: [ParsedScript]) -> PaginatedScript {
        let blocks = makeBlocks(files)
        let sceneCount = blocks.filter { $0.kind == .heading }.count
        if let anchors = production?.pages, !anchors.isEmpty {
            return placeLocked(blocks, anchors: anchors, files: files, sceneCount: sceneCount)
        }
        let placed = place(blocks, sceneCount: sceneCount)
        return PaginatedScript(pages: markRevisions(placed.pages), sceneEighths: placed.eighths, format: format)
    }

    func makeBlocks(_ files: [ParsedScript]) -> [Block] {
        var blocks: [Block] = []
        var scene: Int?
        var sceneCount = 0
        var lastSpeaker: String?
        let labels = production?.sceneLabels ?? SceneNumbering.labels(SceneNumbering.scenes(in: files), locked: nil)
        var omitted = production?.omitted ?? []
        func addOmitted(before index: Int) {
            while let next = omitted.first, next.before <= index {
                omitted.removeFirst()
                guard settings.sceneNumbers else { continue }
                var line = PrintedLine(runs: [PrintedRun("OMITTED")], x: format.heading.x, alignment: .left, kind: .sceneHeading)
                line.sceneNumber = next.number
                let source = blocks.last?.source ?? SourceRef(file: 0, line: 0)
                blocks.append(Block(kind: .omitted, rows: [Row(lines: [line], kind: .sceneHeading, breakable: true)], scene: nil, source: source))
            }
        }

        for (fileIndex, parsed) in files.enumerated() {
            let lines = parsed.lines
            var i = 0
            while i < lines.count {
                let line = lines[i]
                let source = SourceRef(file: fileIndex, line: i)
                switch line.kind {
                case .blank, .boneyard, .synopsis, .section:
                    i += 1

                case .pageBreak:
                    blocks.append(Block(kind: .forcedBreak, rows: [], scene: scene, source: source))
                    i += 1

                case .sceneHeading:
                    addOmitted(before: sceneCount)
                    scene = sceneCount
                    let number = settings.sceneNumbers ? (labels.indices.contains(sceneCount) ? labels[sceneCount] : String(sceneCount + 1)) : nil
                    sceneCount += 1
                    lastSpeaker = nil
                    var rows = wrapped(runs(for: line), width: format.heading.width, x: format.heading.x, kind: .sceneHeading, source: source)
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
                        rows += wrapped(lineRuns, width: format.action.width, x: format.action.x, kind: .action,
                                        source: SourceRef(file: fileIndex, line: i))
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
                            rows.append(Row(lines: [PrintedLine(runs: wrappedRuns, x: format.centerLine, alignment: .center, kind: .centered,
                                                                source: SourceRef(file: fileIndex, line: i))], kind: .centered, breakable: true))
                        }
                        i += 1
                    }
                    blocks.append(Block(kind: .centered, rows: rows, scene: scene, source: source))

                case .transition:
                    let text = ScriptEstimate.printedText(of: line)
                    let lineRuns = Emphasis.runs(in: Emphasis.printable(text), enabled: settings.emphasis)
                    let rows = LineWrapper.wrap(lineRuns, width: format.action.width).map {
                        Row(lines: [PrintedLine(runs: $0, x: format.transitionRightEdge, alignment: .right, kind: .transition, source: source)], kind: .transition, breakable: true)
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
                    var items: [(kind: ScriptElementKind, runs: [PrintedRun], line: Int)] = []
                    while i < lines.count, lines[i].kind == .parenthetical || lines[i].kind == .dialogue {
                        items.append((lines[i].kind, runs(for: lines[i]), i))
                        i += 1
                    }
                    var block = Block(kind: .speech, rows: [], scene: scene, source: source, cue: cue, items: items)
                    if isDual, let previous = blocks.last, previous.kind == .speech {
                        blocks.removeLast()
                        block.kind = .dual
                        block.rows = dualRows(left: previous, right: block)
                        block.source = previous.source
                    } else {
                        block.rows = speechRows(cue: cue, items: items, cueX: format.character.x, dialogue: format.dialogue,
                                                parenthetical: format.parenthetical, file: fileIndex, cueLine: source.line)
                    }
                    blocks.append(block)
                }
            }
        }
        addOmitted(before: Int.max)
        // Every line knows its scene, and whether the current revision changed it.
        let changed = production?.changed ?? []
        for index in blocks.indices {
            for row in blocks[index].rows.indices {
                for line in blocks[index].rows[row].lines.indices {
                    blocks[index].rows[row].lines[line].scene = blocks[index].scene
                    if let source = blocks[index].rows[row].lines[line].source, changed.contains(source) {
                        blocks[index].rows[row].lines[line].revised = true
                    }
                }
            }
        }
        return blocks
    }

    private func runs(for line: ScriptLine) -> [PrintedRun] {
        Emphasis.runs(in: Emphasis.printable(ScriptEstimate.printedText(of: line)), enabled: settings.emphasis)
    }

    private func wrapped(_ runs: [PrintedRun], width: Int, x: Double, kind: ScriptElementKind, source: SourceRef?) -> [Row] {
        let lines = LineWrapper.wrap(runs, width: width)
        return lines.enumerated().map { index, lineRuns in
            let text = lineRuns.map(\.text).joined()
            return Row(
                lines: [PrintedLine(runs: lineRuns, x: x, alignment: .left, kind: kind, source: source)],
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

    private func speechRows(cue: String, items: [(kind: ScriptElementKind, runs: [PrintedRun], line: Int)], cueX: Double,
                            dialogue: ScreenplayFormat.Element, parenthetical: ScreenplayFormat.Element,
                            file: Int, cueLine: Int) -> [Row] {
        var rows: [Row] = []
        for wrappedCue in LineWrapper.wrap(cue, width: format.character.width) {
            rows.append(Row(lines: [PrintedLine(runs: [PrintedRun(wrappedCue)], x: cueX, alignment: .left, kind: .character,
                                                source: SourceRef(file: file, line: cueLine))], kind: .character, breakable: false))
        }
        for item in items {
            let element = item.kind == .parenthetical ? parenthetical : dialogue
            var itemRows = wrapped(item.runs, width: element.width, x: element.x, kind: item.kind, source: SourceRef(file: file, line: item.line))
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
                parenthetical: .init(x: start + 0.3, width: width - 4),
                file: block.source.file, cueLine: block.source.line
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

    /// Lays blocks onto pages from the top of a fresh page.
    private func place(_ blocks: [Block], sceneCount: Int) -> (pages: [PrintedPage], eighths: [Int]) {
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
            if page.firstSource == nil {
                page.firstSource = block.source
                page.startSource = block.source
                page.startRow = block.consumed
            }
            page.lastSource = block.source
            y += gap
            for row in rows {
                for line in row.lines { page.rows.append(PrintedRow(row: y, line: line)) }
                y += 1
            }
            if let scene = block.scene { sceneRowsOnPage[scene, default: 0] += gap + rows.count }
        }

        var queue = blocks[...]
        while let block = queue.popFirst() {
            if block.kind == .forcedBreak {
                if y > 0 { finishPage() }
                continue
            }
            guard !block.rows.isEmpty else { continue }
            let gap = y == 0 ? 0 : ((block.kind == .heading || block.kind == .omitted) ? format.headingSpacing : 1)
            var keep = 0
            if block.kind == .heading, let next = queue.first, next.kind != .heading, next.kind != .omitted,
               next.kind != .forcedBreak, !next.rows.isEmpty {
                keep = 1 + min(next.rows.count, next.kind == .speech ? 3 : 2)
            }

            if y + gap + block.rows.count + keep <= capacity {
                put(block.rows, gap: gap, block: block)
                continue
            }
            let available = capacity - y - gap
            if keep == 0, let (first, rest) = split(block, available: available) {
                put(first.rows, gap: gap, block: block)
                finishPage()
                queue.insert(rest, at: queue.startIndex)
                continue
            }
            if y > 0 {
                finishPage()
                queue.insert(block, at: queue.startIndex)
                continue
            }
            // Taller than a whole page and can't split by the rules: cut it.
            let cut = split(block, available: capacity) ?? Self.cut(block, at: capacity)
            put(cut.0.rows, gap: 0, block: block)
            if !cut.1.rows.isEmpty {
                finishPage()
                queue.insert(cut.1, at: queue.startIndex)
            }
        }
        if !page.rows.isEmpty || pages.isEmpty { finishPage() }
        return (pages, eighths)
    }

    /// A plain cut after `count` rows (no MORE/CONT'D), for blocks taller than a page.
    private static func cut(_ block: Block, at count: Int) -> (Block, Block) {
        var first = block, rest = block
        first.rows = Array(block.rows.prefix(count))
        rest.rows = Array(block.rows.dropFirst(count))
        rest.consumed = block.consumed + max(count - block.leadingExtra, 0)
        rest.leadingExtra = 0
        return (first, rest)
    }

    // MARK: - Locked pages

    /// Each locked page starts where it started when locked. Content that no
    /// longer fits flows onto A-pages (`12A`, `12B`); a page whose start was
    /// cut prints as OMITTED.
    private func placeLocked(_ blocks: [Block], anchors: [PageAnchor], files: [ParsedScript], sceneCount: Int) -> PaginatedScript {
        // Where each anchor falls: a block index, and printed lines into that block.
        struct Mark { var anchor: PageAnchor; var block: Int; var row: Int }
        var marks: [Mark] = []
        var omittedPages: [(after: Int, label: String)] = []
        for anchor in anchors {
            guard let source = PageAnchors.resolve(anchor, files: files),
                  let block = blocks.firstIndex(where: { $0.kind != .omitted && $0.kind != .forcedBreak && $0.source == source })
                    ?? blocks.firstIndex(where: { $0.kind != .omitted && $0.rows.contains { $0.lines.contains { $0.source == source } } })
            else {
                omittedPages.append((marks.count, anchor.page))
                continue
            }
            let row = blocks[block].source == source ? min(anchor.row, max(blocks[block].rows.count - 1, 0)) : 0
            marks.append(Mark(anchor: anchor, block: block, row: row))
        }
        // Text moved around: keep anchors in script order.
        marks.sort { ($0.block, $0.row) < ($1.block, $1.row) }
        if marks.isEmpty || marks[0].block != 0 || marks[0].row != 0 {
            // Content before the first anchor belongs to the first page.
            if !marks.isEmpty { marks[0] = Mark(anchor: marks[0].anchor, block: 0, row: 0) }
        }

        // Cut the blocks into one run per locked page.
        var segments: [[Block]] = [[]]
        var next = 1
        for (blockIndex, original) in blocks.enumerated() {
            var block = original
            while next < marks.count, marks[next].block == blockIndex {
                let at = marks[next].row - block.consumed + block.leadingExtra
                if at > block.leadingExtra, at < block.rows.count {
                    // The page broke inside this block when it was locked.
                    let (first, rest) = forcedSplit(block, at: at)
                    segments[segments.count - 1].append(first)
                    block = rest
                }
                segments.append([])
                next += 1
            }
            segments[segments.count - 1].append(block)
        }

        var pages: [PrintedPage] = []
        var eighths = Array(repeating: 0, count: sceneCount)
        func addOmittedPages(after count: Int) {
            for item in omittedPages where item.after == count {
                var page = PrintedPage(number: pages.count + 1, rows: [
                    PrintedRow(row: format.linesPerPage / 2, line: PrintedLine(runs: [PrintedRun("OMITTED")], x: format.centerLine, alignment: .center, kind: .centered)),
                ])
                page.pageLabel = item.label
                page.omitted = true
                pages.append(page)
            }
        }
        addOmittedPages(after: 0)
        for (segmentIndex, segment) in segments.enumerated() {
            let placed = place(segment, sceneCount: sceneCount)
            for (scene, count) in placed.eighths.enumerated() { eighths[scene] += count }
            let base = marks.indices.contains(segmentIndex) ? marks[segmentIndex].anchor.page : String(segmentIndex + 1)
            for (offset, var page) in placed.pages.enumerated() {
                page.number = pages.count + 1
                page.pageLabel = offset == 0 ? base : base + Self.letters(offset)
                pages.append(page)
            }
            addOmittedPages(after: segmentIndex + 1)
        }
        return PaginatedScript(pages: markRevisions(pages), sceneEighths: eighths, format: format)
    }

    /// 1 → `A`, 26 → `Z`, 27 → `AA`.
    static func letters(_ n: Int) -> String {
        var n = n, result = ""
        while n > 0 {
            n -= 1
            result = String(UnicodeScalar(65 + n % 26)!) + result
            n /= 26
        }
        return result
    }

    /// Splits at row `at` regardless of the usual rules (the page broke there when it was locked).
    private func forcedSplit(_ block: Block, at: Int) -> (Block, Block) {
        let at = min(max(at, 1), block.rows.count)
        var first = block, rest = block
        if block.kind == .speech {
            let more = Row(lines: [PrintedLine(runs: [PrintedRun("(MORE)")], x: format.character.x, alignment: .left, kind: .character)], kind: .character, breakable: false)
            let cue = block.cue.uppercased().contains("CONT'D") ? block.cue : block.cue + " (CONT'D)"
            let contd = Row(lines: [PrintedLine(runs: [PrintedRun(cue)], x: format.character.x, alignment: .left, kind: .character,
                                                source: block.source, scene: block.scene)], kind: .character, breakable: false)
            first.rows = Array(block.rows[..<at]) + [more]
            rest.rows = [contd] + Array(block.rows[at...])
            rest.leadingExtra = 1
        } else {
            first.rows = Array(block.rows[..<at])
            rest.rows = Array(block.rows[at...])
            rest.leadingExtra = 0
        }
        rest.consumed = block.consumed + at - block.leadingExtra
        return (first, rest)
    }

    /// Pages with a changed line show the current revision in their header.
    private func markRevisions(_ pages: [PrintedPage]) -> [PrintedPage] {
        guard let revision = production?.revision else { return pages }
        return pages.map { page in
            var page = page
            if page.rows.contains(where: \.line.revised) { page.revision = revision }
            return page
        }
    }

    /// Splits a block so the first part fits in `available` rows.
    private func split(_ block: Block, available: Int) -> (Block, Block)? {
        guard let (firstRows, restRows, k) = splitRows(block, available: available) else { return nil }
        var first = block, rest = block
        first.rows = firstRows
        rest.rows = restRows
        rest.consumed = block.consumed + k - block.leadingExtra
        rest.leadingExtra = block.kind == .speech ? 1 : 0
        return (first, rest)
    }

    private func splitRows(_ block: Block, available: Int) -> ([Row], [Row], Int)? {
        let rows = block.rows
        switch block.kind {
        case .action:
            guard rows.count >= 4, available >= 2 else { return nil }
            for k in stride(from: min(available, rows.count - 2), through: 2, by: -1) where rows[k - 1].breakable {
                return (Array(rows[..<k]), Array(rows[k...]), k)
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
                let contd = Row(lines: [PrintedLine(runs: [PrintedRun(cue)], x: format.character.x, alignment: .left, kind: .character,
                                                    source: block.source, scene: block.scene)], kind: .character, breakable: false)
                return (Array(rows[..<k]) + [more], [contd] + Array(rows[k...]), k)
            }
            return nil
        default:
            return nil
        }
    }
}
