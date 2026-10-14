import Foundation

/// What a line of an answer's Markdown is, for drawing block structure that `AttributedString(markdown:)` leaves out
/// (it handles inline formatting only): headings, list items, quotes, rules and table rows.
public enum AIMarkdownLine: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// "- item", "* item", "+ item"; a task item's "[ ]" / "[x]" becomes ☐ / ☑.
    case bullet(indent: Int, text: String)
    /// "1. item", "2) item".
    case numbered(indent: Int, number: String, text: String)
    case quote(String)
    /// "---", "***", "___".
    case rule
    case tableRow([String])
    /// A table's "|---|:---:|" line.
    case tableSeparator
    case blank
    case text(String)

    public static func classify(_ line: String) -> AIMarkdownLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        let indent = indentLevel(line)
        if let first = trimmed.first, "-*_".contains(first), trimmed.count >= 3,
           trimmed.allSatisfy({ $0 == first || $0 == " " }), trimmed.filter({ $0 == first }).count >= 3 {
            return .rule
        }
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix { $0 == "#" }.count
            let rest = trimmed.dropFirst(level)
            if level <= 6, rest.isEmpty || rest.hasPrefix(" ") {
                var text = rest.trimmingCharacters(in: .whitespaces)
                while text.hasSuffix("#") { text.removeLast() }
                return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
            }
        }
        for marker in ["- ", "* ", "+ ", "• "] where trimmed.hasPrefix(marker) {
            var text = String(trimmed.dropFirst(marker.count))
            if text.hasPrefix("[ ] ") {
                text = "☐ " + text.dropFirst(4)
            } else if text.lowercased().hasPrefix("[x] ") {
                text = "☑ " + text.dropFirst(4)
            }
            return .bullet(indent: indent, text: text)
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = trimmed.dropFirst(digits.count)
            if let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().hasPrefix(" ") {
                return .numbered(indent: indent, number: "\(digits)\(mark)",
                                 text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        if trimmed.hasPrefix(">") {
            return .quote(trimmed.drop { $0 == ">" }.trimmingCharacters(in: .whitespaces))
        }
        if trimmed.hasPrefix("|"), trimmed.dropFirst().contains("|") {
            let cells = tableCells(trimmed)
            let isSeparator = !cells.isEmpty && cells.allSatisfy { cell in
                let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return !core.isEmpty && core.allSatisfy { $0 == "-" }
            }
            return isSeparator ? .tableSeparator : .tableRow(cells)
        }
        return .text(line)
    }

    /// The cells of "| a | b |", trimmed.
    public static func tableCells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Nesting from leading spaces: two per level, a tab counts as four.
    static func indentLevel(_ line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 4 } else { break }
        }
        return spaces / 2
    }
}

/// A block of an answer's Markdown, ready to draw: what `AIMarkdownLine` says about each line, grouped (a paragraph's
/// lines, a quote's, a table's rows) and with fenced code apart. A fence that isn't closed yet (the answer is still
/// streaming) is a code block up to the end.
public enum AIMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// Inline Markdown, its lines joined by "\n".
    case paragraph(String)
    /// A list item: "•" or "☐"/"☑"-led text for bullets, "3." for numbered ones.
    case listItem(indent: Int, marker: String, text: String)
    case quote(String)
    case rule
    /// Rows of cells; `header` when the first row is the table's head (a separator line follows it).
    case table(rows: [[String]], header: Bool)
    case code(String, language: String)

    public static func parse(_ markdown: String) -> [AIMarkdownBlock] {
        var blocks: [AIMarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var tableHeader = false
        var code: [String]?
        var fence = ""
        var language = ""

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(rows: table, header: tableHeader)) }
            table = []
            tableHeader = false
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushTable()
        }

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let lines = code {
                if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == fence.first }) {
                    blocks.append(.code(lines.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    code = lines + [line]
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let mark = trimmed.first!
                fence = String(trimmed.prefix { $0 == mark })
                language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            switch AIMarkdownLine.classify(line) {
            case .blank:
                flushAll()
            case .heading(let level, let text):
                flushAll()
                blocks.append(.heading(level: level, text: text))
            case .bullet(let indent, let text):
                flushAll()
                if text.hasPrefix("☐ ") || text.hasPrefix("☑ ") {
                    blocks.append(.listItem(indent: indent, marker: String(text.prefix(1)),
                                            text: String(text.dropFirst(2))))
                } else {
                    blocks.append(.listItem(indent: indent, marker: "•", text: text))
                }
            case .numbered(let indent, let number, let text):
                flushAll()
                blocks.append(.listItem(indent: indent, marker: number, text: text))
            case .quote(let text):
                flushParagraph()
                flushTable()
                quote.append(text)
            case .rule:
                flushAll()
                blocks.append(.rule)
            case .tableRow(let cells):
                flushParagraph()
                flushQuote()
                table.append(cells)
            case .tableSeparator:
                if table.count == 1 { tableHeader = true }
            case .text(let text):
                let text = text.trimmingCharacters(in: .whitespaces)
                // An indented line right under a list item goes on with that item.
                if paragraph.isEmpty, quote.isEmpty, table.isEmpty, line.first == " " || line.first == "\t",
                   case .listItem(let indent, let marker, let item)? = blocks.last {
                    blocks[blocks.count - 1] = .listItem(indent: indent, marker: marker, text: item + "\n" + text)
                } else {
                    flushQuote()
                    flushTable()
                    paragraph.append(text)
                }
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"), language: language)) }
        flushAll()
        return blocks
    }

    /// The text of every code block, for copying the code of an answer.
    public static func code(in markdown: String) -> [String] {
        parse(markdown).compactMap { block in
            if case .code(let code, _) = block { return code }
            return nil
        }
    }
}
