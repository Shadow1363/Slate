import Foundation
import SlateCore

/// Slate → Final Draft `.fdx` (FinalDraft XML, version 5).
///
/// Scene IDs travel in a `SlateSceneID` attribute that Final Draft ignores,
/// so a round trip through Slate keeps them. Boneyard and synopsis lines
/// aren't exported.
public enum FDXExporter {
    public static func export(titlePage: String, files: [(name: String, text: String)]) -> String {
        let root = XMLElement(name: "FinalDraft")
        root.addAttribute(attribute("DocumentType", "Script"))
        root.addAttribute(attribute("Template", "No"))
        root.addAttribute(attribute("Version", "5"))

        let content = XMLElement(name: "Content")
        var sceneNumber = 0
        var pendingDual: XMLElement?
        for file in files {
            let parsed = ScriptParser.parse(file.text)
            var i = 0
            while i < parsed.lines.count {
                let line = parsed.lines[i]
                let text = ScriptEstimate.printedText(of: line)
                switch line.kind {
                case .sceneHeading:
                    sceneNumber += 1
                    let paragraph = self.paragraph("Scene Heading", text)
                    paragraph.addAttribute(attribute("Number", "\(sceneNumber)"))
                    if let id = parsed.scenes.first(where: { $0.headingLine == i })?.sceneID {
                        paragraph.addAttribute(attribute("SlateSceneID", id))
                    }
                    content.addChild(paragraph)
                case .action, .lyric:
                    // Lines of one paragraph (single line breaks) stay one FDX paragraph.
                    var paragraphLines = [text]
                    while i + 1 < parsed.lines.count, [.action, .lyric].contains(parsed.lines[i + 1].kind) {
                        i += 1
                        paragraphLines.append(ScriptEstimate.printedText(of: parsed.lines[i]))
                    }
                    content.addChild(self.paragraph("Action", paragraphLines.joined(separator: "\n")))
                case .centered:
                    func centeredText(_ value: String) -> String {
                        var body = value
                        if body.hasSuffix("<") { body.removeLast() }
                        return body.trimmingCharacters(in: .whitespaces)
                    }
                    var paragraphLines = [centeredText(text)]
                    while i + 1 < parsed.lines.count, parsed.lines[i + 1].kind == .centered {
                        i += 1
                        paragraphLines.append(centeredText(ScriptEstimate.printedText(of: parsed.lines[i])))
                    }
                    let paragraph = self.paragraph("Action", paragraphLines.joined(separator: "\n"))
                    paragraph.addAttribute(attribute("Alignment", "Center"))
                    content.addChild(paragraph)
                case .transition:
                    content.addChild(self.paragraph("Transition", text))
                case .pageBreak:
                    let paragraph = self.paragraph("Action", "")
                    paragraph.addAttribute(attribute("StartsNewPage", "Yes"))
                    content.addChild(paragraph)
                case .character:
                    // A speech: cue plus its parentheticals and dialogue.
                    var cue = text
                    let isDual = cue.hasSuffix("^")
                    if isDual { cue = String(cue.dropLast()).trimmingCharacters(in: .whitespaces) }
                    var speech = [self.paragraph("Character", cue)]
                    while i + 1 < parsed.lines.count, [.parenthetical, .dialogue].contains(parsed.lines[i + 1].kind) {
                        i += 1
                        let next = parsed.lines[i]
                        speech.append(self.paragraph(next.kind == .parenthetical ? "Parenthetical" : "Dialogue", ScriptEstimate.printedText(of: next)))
                    }
                    if isDual, let dual = pendingDual {
                        speech.forEach(dual.addChild)
                        pendingDual = nil
                    } else if i + 2 < parsed.lines.count, nextCueIsDual(parsed, after: i) {
                        let holder = XMLElement(name: "Paragraph")
                        let dual = XMLElement(name: "DualDialogue")
                        speech.forEach(dual.addChild)
                        holder.addChild(dual)
                        content.addChild(holder)
                        pendingDual = dual
                    } else {
                        speech.forEach(content.addChild)
                    }
                case .parenthetical, .dialogue:
                    content.addChild(self.paragraph("Dialogue", text))
                case .blank, .boneyard, .synopsis, .section:
                    break
                }
                i += 1
            }
        }
        root.addChild(content)

        let title = TitlePage.parse(titlePage)
        if !title.isEmpty {
            let page = XMLElement(name: "TitlePage")
            let pageContent = XMLElement(name: "Content")
            func add(_ values: [String], alignment: String) {
                for value in values {
                    let p = self.paragraph("Text", value)
                    p.addAttribute(attribute("Alignment", alignment))
                    pageContent.addChild(p)
                }
            }
            add(title.values("Title"), alignment: "Center")
            add(title.values("Credit"), alignment: "Center")
            add(title.values("Author") + title.values("Authors"), alignment: "Center")
            add(title.values("Source"), alignment: "Center")
            add(title.values("Draft date"), alignment: "Center")
            add(title.values("Contact"), alignment: "Left")
            page.addChild(pageContent)
            root.addChild(page)
        }

        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        document.isStandalone = false
        return document.xmlString(options: [.nodePrettyPrint]) + "\n"
    }

    private static func nextCueIsDual(_ parsed: ParsedScript, after index: Int) -> Bool {
        var j = index + 1
        while j < parsed.lines.count, parsed.lines[j].kind == .blank { j += 1 }
        return j < parsed.lines.count && parsed.lines[j].kind == .character && parsed.lines[j].text.trimmingCharacters(in: .whitespaces).hasSuffix("^")
    }

    private static func attribute(_ name: String, _ value: String) -> XMLNode {
        XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
    }

    /// `<Paragraph Type="…">` with one `<Text>` per emphasis run.
    static func paragraph(_ type: String, _ text: String) -> XMLElement {
        let paragraph = XMLElement(name: "Paragraph")
        paragraph.addAttribute(attribute("Type", type))
        for run in Emphasis.runs(in: Emphasis.printable(text)) {
            let element = XMLElement(name: "Text", stringValue: run.text)
            var styles: [String] = []
            if run.bold { styles.append("Bold") }
            if run.italic { styles.append("Italic") }
            if run.underline { styles.append("Underline") }
            if !styles.isEmpty { element.addAttribute(attribute("Style", styles.joined(separator: "+"))) }
            paragraph.addChild(element)
        }
        return paragraph
    }
}

public enum FDXError: Error, LocalizedError {
    case notFinalDraft

    public var errorDescription: String? { "This file isn't a Final Draft (.fdx) script." }
}

/// Final Draft `.fdx` → Slate.
public enum FDXImporter {
    public static func convert(_ data: Data) throws -> ImportedScript {
        let document = try XMLDocument(data: data)
        guard let root = document.rootElement(), root.name == "FinalDraft" else { throw FDXError.notFinalDraft }

        var lines: [String] = []
        var previous: String?
        var usedIDs: Set<String> = []
        var pendingTags: [(line: Int, id: String?, number: String?)] = []

        func blankBefore() {
            if let last = lines.last, !last.isEmpty { lines.append("") }
        }

        func add(_ paragraph: XMLElement, dual: Bool = false) {
            let type = paragraph.attribute(forName: "Type")?.stringValue ?? "Action"
            let text = fountainText(of: paragraph)
            let centered = paragraph.attribute(forName: "Alignment")?.stringValue == "Center"
            if paragraph.attribute(forName: "StartsNewPage")?.stringValue == "Yes" {
                blankBefore()
                lines.append("===")
            }
            switch type {
            case "Scene Heading":
                blankBefore()
                pendingTags.append((lines.count, paragraph.attribute(forName: "SlateSceneID")?.stringValue,
                                    paragraph.attribute(forName: "Number")?.stringValue))
                lines.append(ScriptEditing.convert(text, to: .sceneHeading))
            case "Character":
                blankBefore()
                var cue = ScriptParser.isCharacterCue(text) ? text : "@" + text
                if dual { cue += " ^" }
                lines.append(cue)
            case "Parenthetical":
                if previous != "Character" && previous != "Dialogue" && previous != "Parenthetical" { blankBefore() }
                lines.append(text.hasPrefix("(") ? text : "(\(text))")
            case "Dialogue":
                if previous != "Character" && previous != "Dialogue" && previous != "Parenthetical" { blankBefore() }
                lines.append(text.isEmpty ? "  " : text)
            case "Transition":
                blankBefore()
                lines.append(ScriptEditing.convert(text, to: .transition))
            default: // Action, General, Shot, Cast List…
                guard !text.isEmpty else { break }
                blankBefore()
                for part in text.components(separatedBy: "\n") {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    lines.append(centered ? ">\(trimmed)<" : ScriptEditing.convert(trimmed, to: .action))
                }
            }
            previous = type
        }

        for paragraph in root.elements(forName: "Content").first?.elements(forName: "Paragraph") ?? [] {
            if let dual = paragraph.elements(forName: "DualDialogue").first {
                var seenCue = 0
                for inner in dual.elements(forName: "Paragraph") {
                    let isCue = inner.attribute(forName: "Type")?.stringValue == "Character"
                    if isCue { seenCue += 1 }
                    add(inner, dual: isCue && seenCue == 2)
                }
            } else {
                add(paragraph)
            }
        }

        // Scene tags: keep Slate IDs from a previous export, otherwise assign new ones.
        usedIDs = Set(pendingTags.compactMap(\.id))
        for tag in pendingTags {
            let id: String
            if let existing = tag.id {
                id = existing
            } else {
                id = ScriptBook.nextSceneID(existing: usedIDs)
                usedIDs.insert(id)
            }
            let number = tag.number.map { " number=\($0)" } ?? ""
            lines[tag.line] += " {#\(id)\(number)}"
        }

        return ImportedScript(titlePage: titlePage(from: root), files: [.init(name: "script.md", text: lines.joined(separator: "\n") + "\n")])
    }

    /// The paragraph's `<Text>` runs, with styles turned back into Fountain emphasis.
    static func fountainText(of paragraph: XMLElement) -> String {
        var result = ""
        for text in paragraph.elements(forName: "Text") {
            let value = text.stringValue ?? ""
            let style = text.attribute(forName: "Style")?.stringValue ?? ""
            var open = "", close = ""
            let bold = style.contains("Bold"), italic = style.contains("Italic"), underline = style.contains("Underline")
            if underline { open += "_"; close = "_" + close }
            if bold && italic { open += "***"; close = "***" + close }
            else if bold { open += "**"; close = "**" + close }
            else if italic { open += "*"; close = "*" + close }
            if value.trimmingCharacters(in: .whitespaces).isEmpty || open.isEmpty {
                result += value
            } else {
                // Keep spaces outside the markers so they pair up.
                let leading = value.prefix { $0 == " " }
                let trailing = String(value.reversed().prefix { $0 == " " })
                let core = value.trimmingCharacters(in: .whitespaces)
                result += leading + open + core + close + trailing
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Title page heuristics: the first centred lines are the title, a
    /// "written by" line is the credit, centred lines after it are authors,
    /// left-aligned lines are the contact.
    static func titlePage(from root: XMLElement) -> String {
        guard let content = root.elements(forName: "TitlePage").first?.elements(forName: "Content").first else { return "" }
        var title: [String] = [], credit: [String] = [], authors: [String] = [], contact: [String] = [], other: [String] = []
        var stage = 0 // 0 title, 1 after credit
        for paragraph in content.elements(forName: "Paragraph") {
            let text = fountainText(of: paragraph)
            guard !text.isEmpty else { continue }
            let alignment = paragraph.attribute(forName: "Alignment")?.stringValue ?? "Left"
            let lower = text.lowercased()
            if alignment != "Center" {
                contact.append(text)
            } else if lower.hasSuffix(" by") || lower == "by" {
                credit.append(text)
                stage = 1
            } else if stage == 0 {
                title.append(text)
            } else if authors.isEmpty {
                authors.append(text)
            } else {
                other.append(text)
            }
        }
        var fields: [TitlePage.Field] = []
        if !title.isEmpty { fields.append(.init(key: "Title", values: title)) }
        if !credit.isEmpty { fields.append(.init(key: "Credit", values: credit)) }
        if !authors.isEmpty { fields.append(.init(key: "Author", values: authors)) }
        if let date = other.last { fields.append(.init(key: "Draft date", values: [date])) }
        if other.count > 1 { fields.append(.init(key: "Source", values: Array(other.dropLast()))) }
        if !contact.isEmpty { fields.append(.init(key: "Contact", values: contact)) }
        return fields.isEmpty ? "" : TitlePage(fields: fields).text
    }
}
